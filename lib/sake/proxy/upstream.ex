defmodule Sake.Proxy.Upstream do
  @moduledoc false
  # The process of a `Sake.Proxy`: it keeps the proxy's upstream sessions
  # and lists in an ETS table it owns, and, for a stdio upstream, the one
  # subprocess every principal shares.
  #
  # An HTTP upstream session is a `Sake.Client.Session` value: the request
  # process takes it from the table, uses it, and puts back what the call
  # returned (a renewed legacy session ID, refreshed tokens). Sessions are
  # keyed by the principal and a digest of its credentials, so that one
  # principal's session is never another's, and a new token gets a new
  # session. A stdio upstream is one process for everyone, checked out by
  # one request at a time: its server cannot tell the questions and log
  # messages of concurrent callers apart.
  #
  # It also runs the proxy's `Sake.Proxy.Watcher`, when there is one to
  # run, and starts it again when it fails.

  use GenServer
  require Logger

  alias Sake.Client.Session
  alias Sake.Proxy.{Specs, Watcher}

  @sweep_interval 60_000
  @failure_ttl 5_000
  @max_pages 100

  # The fields of a session that belong to one call: they are put back as
  # they were when the session was taken.
  @call_fields [:on_input, :sampling, :roots, :on_notification, :capabilities, :log_level, :tasks]

  # The capabilities an upstream session declares when it opens (a legacy
  # `initialize`): everything the proxy can pass on to its own clients.
  @capabilities %{"elicitation" => %{}, "sampling" => %{}, "roots" => %{"listChanged" => false}}

  @defaults [
    tools: true,
    prompts: true,
    resources: true,
    scope: [],
    scopes: %{},
    list_ttl: 60_000,
    idle_timeout: 600_000,
    connect: []
  ]

  # ---- configuration

  @doc false
  def start_link(proxy, opts) do
    config = configure!(proxy, opts)
    GenServer.start_link(__MODULE__, {proxy, config}, name: proxy)
  end

  @doc "The proxy's configuration: what its child spec started it with, or what `use` gave."
  @spec config(module()) :: keyword()
  def config(proxy) do
    case :persistent_term.get({__MODULE__, proxy}, nil) do
      nil -> Keyword.merge(@defaults, proxy.__sake_proxy__())
      config -> config
    end
  end

  defp configure!(proxy, opts) do
    unknown = Keyword.keys(opts) -- Sake.Proxy.proxy_keys()

    if unknown != [] do
      raise ArgumentError, "#{inspect(proxy)}: unknown proxy options #{inspect(unknown)}"
    end

    config = Keyword.merge(@defaults, opts)

    case config[:upstream] do
      url when is_binary(url) ->
        :ok

      {:stdio, command, args} when is_binary(command) and is_list(args) ->
        :ok

      other ->
        raise ArgumentError,
              "#{inspect(proxy)}: upstream: must be a URL or {:stdio, command, args}, got #{inspect(other)}"
    end

    Keyword.update!(config, :scope, &List.wrap/1)
  end

  defp stdio?(config), do: match?({:stdio, _, _}, config[:upstream])

  # ---- calls

  @doc """
  Runs `fun` with the principal's upstream session and keeps the session
  it returns. A session the upstream refused (a 401, an expired legacy
  session, a stdio server that went away) is opened again once.
  """
  @spec call(module(), Sake.Context.t(), (Session.t() ->
                                            {:ok, term(), Session.t()}
                                            | {:error, term(), Session.t()})) ::
          {:ok, term()} | {:error, term()}
  def call(proxy, ctx, fun) do
    running!(proxy)
    attempt(proxy, config(proxy), ctx, fun, false)
  end

  # The credentials are asked for on each attempt: after a refusal, the
  # host may have renewed them.
  defp attempt(proxy, config, ctx, fun, retried?) do
    with {:ok, key, headers} <- key(proxy, config, ctx) do
      case run(proxy, config, key, headers, fun) do
        {:error, _reason} = error when retried? -> error
        {:error, reason} = error -> retry(proxy, config, ctx, fun, key, reason, error)
        ok -> ok
      end
    end
  end

  defp retry(proxy, config, ctx, fun, key, reason, error) do
    if refused?(reason) do
      drop(proxy, key)
      attempt(proxy, config, ctx, fun, true)
    else
      error
    end
  end

  defp key(proxy, config, ctx) do
    if stdio?(config) do
      {:ok, :shared, []}
    else
      case credentials(proxy, ctx) do
        {:ok, headers, digest} -> {:ok, {Sake.Tasks.principal(ctx), digest}, headers}
        {:error, message} -> {:error, {:credentials, message}}
      end
    end
  end

  # What a fresh session may cure: refused credentials (which the host
  # may have renewed since), a legacy session the upstream forgot, a
  # stdio server that exited.
  defp refused?({:unauthorized, _challenge}), do: true
  defp refused?({:session_gone, _reason}), do: true
  defp refused?(:closed), do: true
  defp refused?(_reason), do: false

  defp run(proxy, _config, :shared, _headers, fun) do
    case GenServer.call(proxy, :checkout, :infinity) do
      {:ok, session} -> run_checked_out(proxy, session, fun)
      {:error, reason} -> {:error, reason}
    end
  end

  defp run(proxy, config, key, headers, fun) do
    with {:ok, session} <- session(proxy, config, key, headers) do
      {result, returned} = finish(fun.(session), session)
      store(proxy, key, returned)
      result
    end
  end

  # The shared session goes back whatever happened to the call; one that
  # was abandoned (a question passed on to the client, see
  # `Sake.Client.Transport`) goes back as it was taken.
  defp run_checked_out(proxy, session, fun) do
    {result, returned} = finish(fun.(session), session)
    GenServer.cast(proxy, {:checkin, self(), returned})
    result
  catch
    kind, reason ->
      GenServer.cast(proxy, {:checkin, self(), nil})
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  # A legacy upstream answers a request on a session it no longer knows
  # with a 404 (a modern one may answer an unknown method so too).
  defp finish({:ok, value, returned}, session), do: {{:ok, value}, put_back(returned, session)}

  defp finish({:error, {:http, 404, _body} = reason, %Session{era: :legacy} = returned}, session),
    do: {{:error, {:session_gone, reason}}, put_back(returned, session)}

  defp finish({:error, reason, returned}, session),
    do: {{:error, reason}, put_back(returned, session)}

  defp put_back(returned, session), do: Map.merge(returned, Map.take(session, @call_fields))

  # Every call gets IDs of its own: a late answer to an abandoned call can
  # never be taken for the answer to a later one.
  @doc "A fresh base for a call's JSON-RPC IDs."
  @spec ids(Session.t()) :: Session.t()
  def ids(session),
    do: %{session | next_id: System.unique_integer([:positive, :monotonic]) * 1_000_000}

  defp session(proxy, config, key, headers) do
    case :ets.lookup(proxy, {:session, key}) do
      [{_, session, _used}] ->
        :ets.update_element(proxy, {:session, key}, {3, now()})
        {:ok, ids(session)}

      [] ->
        with {:ok, session} <- connect(config, headers) do
          store(proxy, key, session)
          {:ok, ids(session)}
        end
    end
  end

  # A call that ends after its proxy stopped (a task's last poll, say) has
  # no table to put its session back in.
  defp store(proxy, key, session) do
    :ets.insert(proxy, {{:session, key}, session, now()})
  rescue
    ArgumentError -> true
  end

  defp drop(proxy, :shared), do: GenServer.call(proxy, :drop)
  defp drop(proxy, key), do: :ets.delete(proxy, {:session, key})

  @doc "Opens a session with the upstream, with the proxy's `connect:` options and `headers`."
  @spec connect(keyword(), [{String.t(), String.t()}]) :: {:ok, Session.t()} | {:error, term()}
  def connect(config, headers) do
    opts = config[:connect]

    opts =
      opts
      |> Keyword.put(:headers, (opts[:headers] || []) ++ headers)
      |> Keyword.put_new(
        :capabilities,
        Map.put(@capabilities, "extensions", Sake.UI.client_capability())
      )
      |> Keyword.put_new(:client_info, %{"name" => "sake-proxy", "version" => Sake.version()})

    Sake.Client.connect(config[:upstream], opts)
  end

  # ---- credentials

  defp credentials(proxy, ctx) do
    if function_exported?(proxy, :credentials, 1),
      do: proxy.credentials(ctx) |> credential_headers(),
      else: {:ok, [], nil}
  end

  defp credential_headers({:bearer, token}) when is_binary(token),
    do: digest([{"authorization", "Bearer " <> token}])

  defp credential_headers({:headers, headers}) when is_list(headers), do: digest(headers)
  defp credential_headers(:none), do: {:ok, [], nil}
  defp credential_headers({:error, message}) when is_binary(message), do: {:error, message}

  defp credential_headers(other) do
    Logger.error("Sake.Proxy: credentials/1 returned #{inspect(other)}")
    {:error, "The proxy has no credentials for the upstream server."}
  end

  # Only a digest of the credentials keys the session: the table never
  # holds them as a key, and a new token gets a session of its own.
  defp digest(headers),
    do: {:ok, headers, :crypto.hash(:sha256, :erlang.term_to_binary(headers))}

  # ---- lists

  @doc """
  The upstream's components of `kind` for the request's principal, as
  specs (`Sake.Proxy.Specs`), and what is left of their ttl: from the
  table while they are fresh, else from the upstream. A failure is
  remembered for a few seconds, so that an upstream that is down is not
  asked by every request.
  """
  @spec list(module(), :tools | :resources | :prompts, Sake.Context.t()) ::
          {:ok, [struct()], pos_integer()} | :error
  def list(proxy, kind, ctx) do
    running!(proxy)
    config = config(proxy)

    with true <- config[kind] != false,
         {:ok, key, _headers} <- key(proxy, config, ctx) do
      cached(proxy, kind, key) || fetch(proxy, kind, key, ctx)
    else
      _ -> :error
    end
  end

  # A list from the table is good for what is left of its ttl.
  defp cached(proxy, kind, key) do
    now = now()

    case :ets.lookup(proxy, {:list, key, kind}) do
      [{_, {:ok, entries, _ttl}, expires}] when now < expires -> {:ok, entries, expires - now}
      [{_, :error, expires}] when now < expires -> :error
      _ -> nil
    end
  end

  defp fetch(proxy, kind, key, ctx) do
    entry =
      case call(proxy, ctx, &fetch_kind(&1, kind)) do
        {:ok, {entries, ttl}} ->
          config = config(proxy)
          {:ok, Specs.build(proxy, kind, entries, config), ttl || config[:list_ttl]}

        {:error, reason} ->
          Logger.warning(
            "#{inspect(proxy)} could not list the upstream's #{kind}: #{inspect(reason)}"
          )

          :error
      end

    ttl = if match?({:ok, _, _}, entry), do: elem(entry, 2), else: @failure_ttl
    :ets.insert(proxy, {{:list, key, kind}, entry, now() + ttl})
    entry
  end

  defp fetch_kind(session, :resources) do
    with {:ok, {resources, ttl1}, session} <- paged(session, "resources/list", "resources"),
         {:ok, {templates, ttl2}, session} <-
           paged(session, "resources/templates/list", "resourceTemplates") do
      {:ok, {%{resources: resources, templates: templates}, min_ttl(ttl1, ttl2)}, session}
    end
  end

  defp fetch_kind(session, :tools), do: paged(session, "tools/list", "tools")
  defp fetch_kind(session, :prompts), do: paged(session, "prompts/list", "prompts")

  # A list the upstream does not have (it did not declare the capability)
  # is empty.
  defp paged(session, method, key) do
    capability = method |> String.split("/") |> hd()

    if Map.has_key?(session.server_capabilities || %{}, capability),
      do: page(session, method, key, nil, [], nil, 0),
      else: {:ok, {[], nil}, session}
  end

  defp page(session, method, key, cursor, acc, ttl, n) do
    params = if cursor, do: %{"cursor" => cursor}, else: %{}

    with {:ok, result, session} <- Sake.Client.request(session, method, params) do
      items = acc ++ Enum.filter(List.wrap(result[key]), &is_map/1)

      ttl =
        min_ttl(ttl, if(is_integer(result["ttlMs"]) and result["ttlMs"] > 0, do: result["ttlMs"]))

      case result["nextCursor"] do
        next when is_binary(next) and next != cursor and n + 1 < @max_pages ->
          page(session, method, key, next, items, ttl, n + 1)

        _ ->
          {:ok, {items, ttl}, session}
      end
    end
  end

  defp min_ttl(nil, b), do: b
  defp min_ttl(a, nil), do: a
  defp min_ttl(a, b), do: min(a, b)

  @doc "Forgets every principal's list of `kind`, so that the next request asks the upstream."
  @spec forget_lists(module(), :tools | :resources | :prompts) :: :ok
  def forget_lists(proxy, kind) do
    if :ets.whereis(proxy) != :undefined,
      do: :ets.match_delete(proxy, {{:list, :_, kind}, :_, :_})

    :ok
  end

  @doc """
  Has the proxy's watcher follow the upstream resource `uri`, which a
  client subscribed to.
  """
  @spec follow(module(), String.t()) :: :ok
  def follow(proxy, uri), do: GenServer.cast(proxy, {:follow, uri})

  defp running!(proxy) do
    if :ets.whereis(proxy) == :undefined do
      raise "#{inspect(proxy)} is not running: add it to your supervision tree, after Sake"
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  # ---- the process

  @impl true
  def init({proxy, config}) do
    Process.flag(:trap_exit, true)
    :persistent_term.put({__MODULE__, proxy}, config)
    ^proxy = :ets.new(proxy, [:named_table, :public, :set, read_concurrency: true])
    Process.send_after(self(), :sweep, @sweep_interval)

    state = %{
      proxy: proxy,
      config: config,
      stdio: nil,
      busy: nil,
      queue: :queue.new(),
      watcher: nil
    }

    {:ok, watch(state)}
  end

  defp watch(state) do
    if Watcher.watchable?(state.proxy, state.config) do
      {:ok, pid} = Watcher.start_link(state.proxy, state.config)
      %{state | watcher: pid}
    else
      state
    end
  end

  @impl true
  def handle_call(:checkout, {pid, _tag}, %{busy: nil} = state) do
    case stdio_session(state) do
      {:ok, session} ->
        {:reply, {:ok, ids(session)},
         %{state | stdio: session, busy: {pid, Process.monitor(pid)}}}

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | stdio: nil}}
    end
  end

  def handle_call(:checkout, from, state),
    do: {:noreply, %{state | queue: :queue.in(from, state.queue)}}

  # The watcher of a stdio upstream follows the one subprocess, beside the
  # calls: what it sends (a listen request, a legacy subscription) asks
  # the client nothing and logs nothing, so it need not wait its turn.
  def handle_call(:stdio_session, _from, state) do
    case stdio_session(state) do
      {:ok, session} -> {:reply, {:ok, ids(session)}, %{state | stdio: session}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:drop, _from, state) do
    if state.stdio, do: Sake.Client.close(state.stdio)
    {:reply, :ok, %{state | stdio: nil}}
  end

  @impl true
  def handle_cast({:checkin, pid, session}, %{busy: {pid, ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = if session, do: %{state | stdio: session}, else: state
    {:noreply, next(%{state | busy: nil})}
  end

  def handle_cast({:checkin, _pid, _session}, state), do: {:noreply, state}

  def handle_cast({:follow, uri}, state) do
    if state.watcher, do: GenServer.cast(state.watcher, {:follow, uri})
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{busy: {_, ref}} = state),
    do: {:noreply, next(%{state | busy: nil})}

  def handle_info({:EXIT, pid, reason}, %{watcher: pid} = state) do
    Logger.warning("#{inspect(state.proxy)}: the upstream's watcher failed: #{inspect(reason)}")
    Process.send_after(self(), :watch, 1_000)
    {:noreply, %{state | watcher: nil}}
  end

  def handle_info(:watch, %{watcher: nil} = state), do: {:noreply, watch(state)}

  def handle_info(:sweep, state) do
    sweep(state)
    Process.send_after(self(), :sweep, @sweep_interval)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.stdio, do: Sake.Client.close(state.stdio)
    :persistent_term.erase({__MODULE__, state.proxy})
    :ok
  end

  # The next caller in line gets the session; one that could not be
  # opened is the next caller's error, and the line moves on.
  defp next(state) do
    case :queue.out(state.queue) do
      {{:value, from}, queue} ->
        {:reply, reply, state} = handle_call(:checkout, from, %{state | queue: queue})
        GenServer.reply(from, reply)
        if state.busy, do: state, else: next(state)

      {:empty, _queue} ->
        state
    end
  end

  # The subprocess is started here, so that this process owns it, and
  # started again when it has exited.
  defp stdio_session(%{stdio: %Session{stdio: pid} = session} = state) do
    if Process.alive?(pid), do: {:ok, session}, else: connect(state.config, [])
  end

  defp stdio_session(state), do: connect(state.config, [])

  # Unused sessions and stale lists leave the table; a legacy HTTP session
  # is closed on the way out.
  defp sweep(state) do
    idle_since = now() - state.config[:idle_timeout]

    for {{:session, _key} = key, session, used} <- :ets.tab2list(state.proxy),
        used <= idle_since do
      :ets.delete(state.proxy, key)
      Task.start(fn -> Sake.Client.close(session) end)
    end

    :ets.select_delete(state.proxy, [{{{:list, :_, :_}, :_, :"$1"}, [{:<, :"$1", now()}], [true]}])

    :ok
  end
end
