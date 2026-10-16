defmodule Sake.Proxy.Watcher do
  @moduledoc false
  # Follows an upstream's own notifications for a `Sake.Proxy`, with a
  # session of its own (`Sake.Client.listen/3`), and makes them the
  # proxy's: a list change forgets the cached lists and is broadcast, a
  # resource update is broadcast, both as `Sake.Server` broadcasts of the
  # proxy, which reach the clients of every server that mounts it under
  # its prefix (see `Sake.Plug.Streams`).
  #
  # It runs only when every principal has the same upstream identity (a
  # fixed token, the client's own authorization, a stdio upstream): with
  # `credentials/1`, each principal's upstream may list and announce
  # different things, and one stream per principal is not kept.
  #
  # The resources it follows are those some client subscribed to through
  # the proxy (`follow/2`): a modern upstream's stream is opened again
  # with each new one, a legacy upstream gets a `resources/subscribe`.
  # Started, and restarted after a failure, by `Sake.Proxy.Upstream`.

  use GenServer
  require Logger

  alias Sake.Proxy.Upstream

  @max_uris 1_000
  @min_backoff 1_000
  @max_backoff 30_000
  @refilter_after 100

  @kinds %{"tools" => :tools, "resources" => :resources, "prompts" => :prompts}

  @doc "Whether the proxy's upstream can be followed by one session for everyone."
  @spec watchable?(module(), keyword()) :: boolean()
  def watchable?(proxy, config) do
    case config[:upstream] do
      {:stdio, _command, _args} -> true
      url when is_binary(url) -> not function_exported?(proxy, :credentials, 1)
    end
  end

  @doc "Whether the proxy's clients may subscribe to its resources: the upstream lets the watcher."
  @spec subscribe?(module()) :: boolean()
  def subscribe?(proxy), do: :persistent_term.get({__MODULE__, proxy}, false)

  @spec start_link(module(), keyword()) :: GenServer.on_start()
  def start_link(proxy, config), do: GenServer.start_link(__MODULE__, {proxy, config})

  @impl true
  def init({proxy, config}) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       proxy: proxy,
       config: config,
       session: nil,
       listener: nil,
       uris: [],
       backoff: @min_backoff,
       refilter: false
     }, {:continue, :listen}}
  end

  @impl true
  def handle_continue(:listen, state), do: {:noreply, listen(state)}

  @impl true
  def handle_cast({:follow, uri}, state) do
    if uri in state.uris do
      {:noreply, state}
    else
      state = %{state | uris: Enum.take([uri | state.uris], @max_uris)}
      {:noreply, follow(state, uri)}
    end
  end

  @impl true
  def handle_info({:upstream, method, params}, state),
    do: {:noreply, notified(state, method, params)}

  def handle_info(:listen, state), do: {:noreply, listen(state)}

  def handle_info(:refilter, state) do
    state = stop_listener(%{state | refilter: false})
    {:noreply, listen(state)}
  end

  def handle_info({:EXIT, pid, reason}, %{listener: pid} = state) do
    Logger.debug("#{inspect(state.proxy)}: the upstream's stream ended: #{inspect(reason)}")
    {:noreply, retry(%{state | listener: nil, session: nil})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    :persistent_term.erase({__MODULE__, state.proxy})
    :ok
  end

  # ---- the stream

  defp listen(state) do
    case session(state) do
      {:ok, session} ->
        resources = session.server_capabilities["resources"] || %{}
        :persistent_term.put({__MODULE__, state.proxy}, resources["subscribe"] == true)
        watcher = self()
        filter = filter(state.uris)

        listener =
          spawn_link(fn ->
            exit(
              {:shutdown,
               Sake.Client.listen(session, filter, &send(watcher, {:upstream, &1, &2}))}
            )
          end)

        %{state | session: session, listener: listener}

      {:error, reason} ->
        Logger.warning("#{inspect(state.proxy)} cannot follow the upstream: #{inspect(reason)}")
        retry(state)
    end
  end

  # A stdio upstream is the proxy's one subprocess; an HTTP upstream gets a
  # session of its own, with the proxy's fixed credentials.
  defp session(%{session: session}) when session != nil, do: {:ok, session}

  defp session(%{config: config, proxy: proxy}) do
    case config[:upstream] do
      {:stdio, _command, _args} -> GenServer.call(proxy, :stdio_session, :infinity)
      _url -> Upstream.connect(config, [])
    end
  end

  defp retry(state) do
    Process.send_after(self(), :listen, state.backoff)
    %{state | backoff: min(state.backoff * 2, @max_backoff)}
  end

  defp filter(uris) do
    filter = %{
      "toolsListChanged" => true,
      "resourcesListChanged" => true,
      "promptsListChanged" => true
    }

    if uris == [], do: filter, else: Map.put(filter, "resourceSubscriptions", uris)
  end

  defp stop_listener(%{listener: nil} = state), do: state

  defp stop_listener(%{listener: pid} = state) do
    Process.unlink(pid)
    Process.exit(pid, :kill)
    %{state | listener: nil}
  end

  # ---- following a resource

  # A modern upstream's stream names its subscriptions, so it is opened
  # again (once, for several at once); a legacy session subscribes on the
  # side.
  defp follow(%{session: %{era: :legacy} = session} = state, uri) do
    proxy = state.proxy

    Task.start(fn ->
      case Sake.Client.request(session, "resources/subscribe", %{"uri" => uri}) do
        {:ok, _result, _session} ->
          :ok

        {:error, reason, _session} ->
          Logger.warning("#{inspect(proxy)} cannot follow #{uri}: #{inspect(reason)}")
      end
    end)

    state
  end

  defp follow(%{session: nil} = state, _uri), do: state
  defp follow(%{refilter: true} = state, _uri), do: state

  defp follow(state, _uri) do
    Process.send_after(self(), :refilter, @refilter_after)
    %{state | refilter: true}
  end

  # ---- what the upstream announces

  defp notified(state, "notifications/" <> rest, params) do
    case String.split(rest, "/") do
      [kind, "list_changed"] when is_map_key(@kinds, kind) ->
        Upstream.forget_lists(state.proxy, @kinds[kind])
        Sake.Server.notify_list_changed(state.proxy, @kinds[kind])
        %{state | backoff: @min_backoff}

      ["resources", "updated"] ->
        if is_binary(params["uri"]), do: Sake.Server.resource_updated(state.proxy, params["uri"])
        %{state | backoff: @min_backoff}

      ["subscriptions", "acknowledged"] ->
        %{state | backoff: @min_backoff}

      _other ->
        state
    end
  end

  defp notified(state, _method, _params), do: state
end
