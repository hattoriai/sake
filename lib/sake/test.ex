defmodule Sake.Test do
  @moduledoc """
  Tests for a Sake server: a client connected to the server in memory, the
  MCP counterpart of `Phoenix.ConnTest`.

      import Sake.Test

      test "greets" do
        client = connect(MyApp.MCP, scope: user, scopes: ["greet"])
        assert {:ok, %{text: "Hello, Rui!"}} = call_tool(client, "greet", %{"name" => "Rui"})
        assert {:ok, tools} = list_tools(client)

        assert {:error, {:insufficient_scope, %{scope: ["issues:write"]}}} =
                 call_tool(client, "close_issue", %{"id" => 1})
      end

  The client is a `Sake.Client` whose transport is the server itself:
  every request crosses as JSON into the dispatchers `Sake.Plug` and
  `Sake.Stdio` use, with a real `Sake.Context`, so argument validation,
  scopes, results and errors are the production ones, and every client
  feature works as against a real server (input requests and their
  retries, tasks, MCP Apps, progress and log notifications). The calls
  take and return what `Sake.Client`'s do, without the session: a call
  returns `{:ok, value}` or `{:error, reason}`, a call with nothing to
  return `:ok`, and `session/1` hands the session over when a test needs
  `Sake.Client` itself.

  In `test/test_helper.exs`, `start/1` starts what Sake needs when the
  application does not (see its documentation).

  ## Options

  `connect/2` takes the options of `Sake.Client.connect/2` (`era:`,
  `legacy_version:`, `client_info:`, `capabilities:`, `on_input:`,
  `sampling:`, `roots:`, `on_notification:`, `log_level:`, `tasks:`,
  `task_timeout:`, `ui:`), and:

    * `:scope` — the host's principal, what components see as
      `ctx.scope` (a value, or a function of no arguments called for
      every request). Default `nil`.
    * `:scopes` — the OAuth scopes of a simulated access token. With it,
      every request carries the token, and components are gated by their
      `scope:` as on an endpoint with authorization; without it there is
      no token and no gating, as on an endpoint without.
    * `:subject` — the token's subject, which owns the tasks it starts.
      Defaults to one derived from `:scope`, so two clients with different
      principals are different people; `nil` makes it a machine client's
      token (the client credentials grant), owned by `:client_id`.
    * `:client_id` — the token's client. Default `"sake-test"`.
    * `:acr`, `:auth_time` — how and when the token's person signed in
      (RFC 9470): the authentication context class and a `DateTime`, for
      components with `authentication:`. Default `nil` (unknown), which
      meets no requirement: such a call answers
      `{:error, {:insufficient_user_authentication, challenge}}`.
    * `:reraise` — whether an exception raised by a component fails the
      test with that exception (the default), or becomes the error result
      a client would get (`false`).
    * `:secret` — signs cursors and request states. Default the `Sake`
      configuration's, else a fixed one shared by every test client.

  The era is modern unless `era: :legacy` asks for the handshake.

  ## Answering the server

  `on_input:`, `sampling:` and `roots:` answer the server's requests, and
  turn on their capabilities, exactly as for `Sake.Client`. Two shorter
  forms suit tests: `on_input:` may be a function of one request's
  `params` that returns `{:accept, content}`, `:decline`, `:cancel` or an
  answer map, and `sampling:` a function of the request's `params` that
  returns `{:ok, result}`, `{:error, error}` or the text of the
  assistant's reply.

  Every request the server asks is recorded, for `assert_asked/2`:

      client = connect(MyApp.MCP, on_input: fn _params -> {:accept, %{"name" => "Rui"}} end)
      assert {:ok, %{text: "Hello, Rui!"}} = call_tool(client, "greet", %{})
      assert_asked "elicitation/create", %{"message" => "Who should be greeted?"}

  ## Notifications

  The client asks for progress on every call, and every notification the
  server sends during one is recorded for `assert_notification/2`; pass
  `log_level:` to have the server send log messages too.

  `listen/2` records what a server broadcasts (`Sake.Server.notify_list_changed/2`,
  `Sake.Server.resource_updated/2`), for `assert_list_changed/1` and
  `assert_resource_updated/1`. It sees only the broadcasts of the test
  process and of the processes it started, so tests can run with
  `async: true`; `shared: true` sees every broadcast of the server, from
  any process, for a test that cannot run concurrently with others.

  ## Through a plug

  `plug:` sends the requests through a plug instead, over HTTP as
  `Sake.Client` sends them, with Req running the plug in the test's
  process: the host's endpoint or router, with its pipelines and its
  authorization (`plug: MyAppWeb.Endpoint, path: "/acme/mcp"`), or
  `Sake.Plug` itself (`plug: {Sake.Plug, server: MyApp.MCP}`). `path:` is
  the endpoint's path (default `"/mcp"`) and `headers:` go with every
  request. The stack computes the principal from the request, so `scope:`
  does not apply; `scopes:` issues a real access token for `subject:`
  (see `access_token/1`) and sends it as a bearer token, or, to a server
  that takes DPoP-bound tokens only (`dpop: [required: true]`), bound to a
  key the client signs a DPoP proof with for each request. That token is
  `Sake.Auth`'s: an endpoint whose tokens come from another authorization
  server (`Sake.Auth.External`) does not take it, so send one that server
  accepts in `headers:` (in the test environment, a `verify:` callback
  that knows your test tokens), or test the server through the in-memory
  client, whose `scopes:` token stands for any issuer's. A legacy server's
  questions need the in-memory client, and a task is polled at the
  interval the server suggests, as over the network.

  ## Tasks

  A tool that runs as a task (see `Sake.Tasks`) runs as one here, in the
  background, when `start/1` or the application started tasks.
  `call_tool/3` follows it to its result, and `call_tool_async/3` hands it
  back to drive with `await_task/3`, `get_task/2`, `update_task/3` and
  `cancel_task/2`. Neither sleeps: the client sees the task's status
  change the moment it happens.
  """

  alias Sake.Auth.TokenRecord
  alias Sake.Client.{Session, Transport}
  alias Sake.Plug.Streams
  alias Sake.Test.{Client, Endpoint}

  # The origin of a request through a plug, as `Plug.Test` has it.
  @origin "http://www.example.com"

  @client_options [
    :era,
    :legacy_version,
    :client_info,
    :capabilities,
    :on_input,
    :sampling,
    :roots,
    :log_level,
    :tasks,
    :task_timeout,
    :ui
  ]

  @doc """
  Starts what Sake needs when the application does not start `{Sake,
  ...}` in the test environment: the stream registry (for `listen/2`, a
  legacy server's requests, and tasks) and tasks. What already runs is
  left alone. Call it once, in `test/test_helper.exs`:

      Sake.Test.start()

  `tasks:` takes the `Sake.Tasks` options, or `false` for none.
  """
  @spec start(keyword()) :: :ok
  def start(opts \\ []) do
    children =
      if(Process.whereis(Streams), do: [], else: [Streams.child_spec([])]) ++
        tasks(Keyword.get(opts, :tasks, []))

    if children != [] do
      # Not linked to the caller: the processes outlive the one that
      # started them, for the whole test run.
      {:ok, pid} =
        Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__.Supervisor)

      Process.unlink(pid)
    end

    :ok
  end

  defp tasks(false), do: []
  defp tasks(opts), do: if(Sake.Tasks.running?(), do: [], else: [{Sake.Tasks, opts}])

  @doc """
  Connects a client to `server`, a `Sake.Server` module, in memory. See
  the module documentation for the options. Raises when the server
  refuses the connection.
  """
  @spec connect(module(), keyword()) :: Client.t()
  def connect(server, opts \\ []) do
    owner = self()

    client_opts =
      opts
      |> Keyword.take(@client_options)
      |> Keyword.put_new(:era, :modern)
      |> answer_and_record(owner)
      |> Keyword.put(:on_notification, recorder(owner, opts[:on_notification]))

    {target, client_opts} = target(server, opts, client_opts)

    case Sake.Client.connect(target, client_opts) do
      {:ok, session} ->
        {:ok, pid} = Agent.start_link(fn -> session end)
        %Client{pid: pid, server: server}

      {:error, reason} ->
        raise "Sake.Test could not connect to #{inspect(server)}: #{inspect(reason)}"
    end
  end

  defp target(server, opts, client_opts) do
    case opts[:plug] do
      nil -> {{:local, Endpoint.new(server, Keyword.put(opts, :token, token(opts)))}, client_opts}
      plug -> through(plug, opts, client_opts)
    end
  end

  # Through a plug, as `Sake.Client` sends requests over HTTP, with Req
  # running the plug in this process: the stack decides who is calling,
  # from the request.
  defp through(plug, opts, client_opts) do
    if Keyword.has_key?(opts, :scope) do
      raise ArgumentError,
            "Sake.Test: with plug:, the stack computes the principal; pass headers:, or scopes: and subject: for a bearer token"
    end

    # A legacy server asks its questions on the call's response stream,
    # and the client answers with a request of its own while the call is
    # still open, which a plug run in this process cannot take.
    if client_opts[:era] == :legacy and Enum.any?([:on_input, :sampling, :roots], &opts[&1]) do
      raise ArgumentError,
            "Sake.Test: a legacy server's questions need the in-memory client; leave out plug:"
    end

    url = @origin <> (opts[:path] || "/mcp")
    {url, Keyword.merge(client_opts, [req: [plug: plug]] ++ credentials(opts, url))}
  end

  defp credentials(opts, url) do
    headers = opts[:headers] || []
    opts = Keyword.put_new(opts, :resource, url)

    cond do
      !opts[:scopes] ->
        [headers: headers]

      Sake.Auth.configured() == nil ->
        raise ArgumentError,
              "Sake.Test: scopes: with plug: issues a Sake.Auth token, and Sake.Auth is not configured; for an endpoint on an external authorization server, send a token it accepts in headers:"

      Sake.Auth.Config.dpop_required?(Sake.Auth.config()) ->
        [
          headers: headers,
          auth: [store: {Sake.Test.TokenStore, bound_token(opts)}, static: true]
        ]

      true ->
        [headers: [{"authorization", "Bearer " <> access_token(opts)} | headers]]
    end
  end

  # A token bound to a new key, as `Sake.Client.Auth` keeps one.
  defp bound_token(opts) do
    {pem, jkt} = Sake.Auth.dpop_key()

    %{"access_token" => issue(opts, jkt), "token_type" => "DPoP", "dpop_key" => pem}
  end

  @doc """
  Issues an access token in the `Sake.Auth` store and returns it, for a
  request through a host's endpoint with authorization: `connect/2` with
  `plug:` and `scopes:` sends one, and a `Phoenix.ConnTest` test can put
  it in an `authorization` header itself. `Sake.Auth` must be configured
  (`{Sake, auth: ...}`).

  Options: `subject:` (required: the ID your subject module's `fetch/1`
  takes, or `nil` for a machine client's token), `client_id:` (default
  `"sake-test"`; a machine client's must be registered, see
  `Sake.Auth.Clients.create/2`), `scopes:` (default none), `acr:` and
  `auth_time:` (how and when the person signed in, RFC 9470; default
  unknown), `resource:`
  (the endpoint's URL, which the token is for; default
  `"http://www.example.com/mcp"`, the endpoint of a test request at
  `/mcp`).
  """
  @spec access_token(keyword()) :: String.t()
  def access_token(opts), do: issue(opts, nil)

  defp issue(opts, jkt) do
    unless Keyword.has_key?(opts, :subject) do
      raise ArgumentError,
            "Sake.Test.access_token/1 needs subject: (the ID your subject module fetches), or subject: nil for a machine client"
    end

    Sake.Auth.issue_access_token(Sake.Auth.config(), %{
      client_id: opts[:client_id] || "sake-test",
      subject_id: opts[:subject] && to_string(opts[:subject]),
      scopes: opts[:scopes] || [],
      resource: opts[:resource] || @origin <> "/mcp",
      jkt: jkt,
      acr: opts[:acr],
      auth_time: opts[:auth_time] && DateTime.truncate(opts[:auth_time], :second)
    })
  end

  # ---- the simulated token

  defp token(opts) do
    case opts[:scopes] do
      nil ->
        nil

      scopes ->
        %TokenRecord{
          kind: :access,
          client_id: opts[:client_id] || "sake-test",
          subject_id: subject(opts),
          scopes: scopes,
          acr: opts[:acr],
          auth_time: opts[:auth_time]
        }
    end
  end

  defp subject(opts) do
    case Keyword.fetch(opts, :subject) do
      {:ok, nil} ->
        nil

      {:ok, subject} ->
        to_string(subject)

      :error ->
        "sake-test:" <> Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary(opts[:scope])))
    end
  end

  # ---- answering and recording the server's requests

  defp answer_and_record(opts, owner) do
    opts
    |> update(:on_input, &on_input(&1, owner))
    |> update(:sampling, &sampling(&1, owner))
    |> update(:roots, &roots(&1, owner))
  end

  # Only an option the test gave is wrapped: each one turns on its
  # capability, which the test must not get without asking.
  defp update(opts, key, fun) do
    case opts[key] do
      nil -> opts
      value -> Keyword.put(opts, key, fun.(value))
    end
  end

  defp on_input(fun, owner) do
    fn requests, session ->
      Enum.each(requests, fn {_key, request} -> asked(owner, request) end)
      elicit(fun, requests, session)
    end
  end

  defp elicit(fun, requests, session) when is_function(fun, 2), do: fun.(requests, session)

  defp elicit(fun, requests, _session),
    do: Map.new(requests, fn {key, request} -> {key, elicited(fun.(request["params"]))} end)

  defp elicited({:accept, content}), do: %{"action" => "accept", "content" => content}
  defp elicited(:decline), do: %{"action" => "decline"}
  defp elicited(:cancel), do: %{"action" => "cancel"}
  defp elicited(%{} = answer), do: answer

  defp sampling(fun, owner) do
    fn params, session ->
      asked(owner, %{"method" => "sampling/createMessage", "params" => params})
      fun |> sample(params, session) |> sampled()
    end
  end

  defp sample(fun, params, session) when is_function(fun, 2), do: fun.(params, session)
  defp sample(fun, params, _session), do: fun.(params)

  defp sampled(text) when is_binary(text) do
    {:ok,
     %{
       "role" => "assistant",
       "content" => %{"type" => "text", "text" => text},
       "model" => "sake-test"
     }}
  end

  defp sampled(answer), do: answer

  defp roots(roots, owner) do
    fn session ->
      asked(owner, %{"method" => "roots/list", "params" => %{}})
      if is_function(roots, 1), do: roots.(session), else: roots
    end
  end

  defp asked(owner, request), do: send(owner, {:sake_test_asked, request})

  defp recorder(owner, fun) do
    fn method, params ->
      send(owner, {:sake_test_notification, method, params})
      if fun, do: fun.(method, params)
    end
  end

  # ---- calls

  @doc "The client's `Sake.Client.Session` as it is now, for `Sake.Client` itself."
  @spec session(Client.t()) :: Session.t()
  def session(%Client{pid: pid}), do: Agent.get(pid, & &1)

  @doc "Ends the client."
  @spec close(Client.t()) :: :ok
  def close(%Client{pid: pid} = client) do
    :ok = Sake.Client.close(session(client))
    Agent.stop(pid)
  end

  @doc "See `Sake.Client.list_tools/1`."
  @spec list_tools(Client.t()) :: {:ok, [Sake.Tool.Spec.t()]} | {:error, term()}
  def list_tools(client), do: run(client, &Sake.Client.list_tools/1)

  @doc "See `Sake.Client.call_tool/3`."
  @spec call_tool(Client.t(), String.t(), map()) ::
          {:ok, Sake.Client.ToolResult.t()} | {:error, term()}
  def call_tool(client, name, arguments \\ %{}),
    do: run(client, &Sake.Client.call_tool(&1, name, arguments))

  @doc "See `Sake.Client.call_tool_async/3`."
  @spec call_tool_async(Client.t(), String.t(), map()) ::
          {:ok, Sake.Client.ToolResult.t() | {:task, map()}} | {:error, term()}
  def call_tool_async(client, name, arguments \\ %{}),
    do: run(client, &Sake.Client.call_tool_async(&1, name, arguments))

  @doc "See `Sake.Client.get_task/2`."
  @spec get_task(Client.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_task(client, task_id), do: run(client, &Sake.Client.get_task(&1, task_id))

  @doc "See `Sake.Client.update_task/3`."
  @spec update_task(Client.t(), String.t(), map()) :: :ok | {:error, term()}
  def update_task(client, task_id, responses),
    do: run(client, &Sake.Client.update_task(&1, task_id, responses))

  @doc "See `Sake.Client.cancel_task/2`."
  @spec cancel_task(Client.t(), String.t()) :: :ok | {:error, term()}
  def cancel_task(client, task_id), do: run(client, &Sake.Client.cancel_task(&1, task_id))

  @doc """
  Waits until a task (a task map or its ID) is no longer `working`, and
  returns it as `tasks/get` does then: `input_required`, `completed`,
  `failed` or `cancelled`. It wakes when the task's status changes, not on
  a timer. `{:error, :timeout}` after `timeout` ms.
  """
  @spec await_task(Client.t(), String.t() | map(), timeout()) :: {:ok, map()} | {:error, term()}
  def await_task(client, task, timeout \\ 5_000)

  def await_task(client, %{"taskId" => id}, timeout), do: await_task(client, id, timeout)

  def await_task(client, task_id, timeout) when is_binary(task_id) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await(client, task_id, deadline)
  end

  defp await(client, task_id, deadline) do
    with {:ok, task} <- get_task(client, task_id) do
      left = deadline - System.monotonic_time(:millisecond)

      cond do
        task["status"] != "working" ->
          {:ok, task}

        left <= 0 ->
          {:error, :timeout}

        true ->
          :ok = Transport.wait(session(client), task, min(task["pollIntervalMs"] || 1_000, left))
          await(client, task_id, deadline)
      end
    end
  end

  @doc "See `Sake.Client.list_resources/1`."
  @spec list_resources(Client.t()) :: {:ok, [map()]} | {:error, term()}
  def list_resources(client), do: run(client, &Sake.Client.list_resources/1)

  @doc "See `Sake.Client.list_resource_templates/1`."
  @spec list_resource_templates(Client.t()) :: {:ok, [map()]} | {:error, term()}
  def list_resource_templates(client), do: run(client, &Sake.Client.list_resource_templates/1)

  @doc "See `Sake.Client.read_resource/2`."
  @spec read_resource(Client.t(), String.t()) :: {:ok, [Sake.Content.t()]} | {:error, term()}
  def read_resource(client, uri), do: run(client, &Sake.Client.read_resource(&1, uri))

  @doc "See `Sake.Client.list_prompts/1`."
  @spec list_prompts(Client.t()) :: {:ok, [map()]} | {:error, term()}
  def list_prompts(client), do: run(client, &Sake.Client.list_prompts/1)

  @doc "See `Sake.Client.get_prompt/3`."
  @spec get_prompt(Client.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def get_prompt(client, name, arguments \\ %{}),
    do: run(client, &Sake.Client.get_prompt(&1, name, arguments))

  @doc "See `Sake.Client.complete/4`."
  @spec complete(
          Client.t(),
          {:prompt, String.t()} | {:resource, String.t()},
          String.t(),
          String.t()
        ) :: {:ok, map()} | {:error, term()}
  def complete(client, ref, argument, value),
    do: run(client, &Sake.Client.complete(&1, ref, argument, value))

  @doc "See `Sake.Client.ping/1`."
  @spec ping(Client.t()) :: :ok | {:error, term()}
  def ping(client), do: run(client, &Sake.Client.ping/1)

  @doc "See `Sake.Client.set_log_level/2`."
  @spec set_log_level(Client.t(), String.t() | atom()) :: :ok | {:error, term()}
  def set_log_level(client, level), do: run(client, &Sake.Client.set_log_level(&1, level))

  # The call runs in the caller, so the client's answers and notifications
  # do too; the session it returns is kept for the next call.
  defp run(%Client{pid: pid} = client, fun) do
    case fun.(session(client)) do
      {:ok, %Session{} = session} ->
        keep(pid, session)
        :ok

      {:ok, value, session} ->
        keep(pid, session)
        {:ok, value}

      {:error, reason, session} ->
        keep(pid, session)
        {:error, reason}
    end
  end

  defp keep(pid, session), do: Agent.update(pid, fn _ -> session end)

  # ---- broadcasts

  @doc """
  Records the broadcasts of `server` (a `Sake.Server` module, or a client
  connected to one) for `assert_list_changed/1` and
  `assert_resource_updated/1`, from now until the calling process ends.

  Only the broadcasts made by the calling process and by the processes it
  started (a tool the test called, a task) are recorded, so concurrent
  tests do not see each other's. `shared: true` records every broadcast
  of the server, from any process: for a broadcast from a process the
  test did not start, in a test with `async: false`.
  """
  @spec listen(module() | Client.t(), keyword()) :: :ok
  def listen(server, opts \\ [])

  def listen(%Client{server: server}, opts), do: listen(server, opts)

  def listen(server, opts) when is_atom(server) do
    owner = if opts[:shared], do: :any, else: self()
    :ok = Streams.unregister_test(server, owner, :sake_test_broadcast)
    Streams.register_test(server, owner, :sake_test_broadcast)
  end

  # ---- assertions

  @doc """
  Asserts that the server sent a notification during a call of this
  test's client: `"notifications/progress"` (`Sake.Progress.report/4`) or
  `"notifications/message"` (`Sake.Progress.log/3`, with `log_level:`).
  `params` is a pattern.

      assert_notification "notifications/progress", %{"progress" => 3, "total" => 10}
  """
  defmacro assert_notification(method, params \\ quote(do: _)) do
    quote do
      require ExUnit.Assertions

      ExUnit.Assertions.assert_receive(
        {:sake_test_notification, unquote(method), unquote(params)}
      )
    end
  end

  @doc "Refutes that the server sent such a notification (see `assert_notification/2`) so far."
  defmacro refute_notification(method, params \\ quote(do: _)) do
    quote do
      require ExUnit.Assertions

      ExUnit.Assertions.refute_received(
        {:sake_test_notification, unquote(method), unquote(params)}
      )
    end
  end

  @doc """
  Asserts that the server asked this test's client something:
  `"elicitation/create"`, `"sampling/createMessage"` or `"roots/list"`,
  with `params` (a pattern).

      assert_asked "elicitation/create", %{"mode" => "form", "message" => "Who?"}
  """
  defmacro assert_asked(method, params \\ quote(do: _)) do
    quote do
      require ExUnit.Assertions

      ExUnit.Assertions.assert_receive(
        {:sake_test_asked, %{"method" => unquote(method), "params" => unquote(params)}}
      )
    end
  end

  @doc "Refutes that the server asked such a thing (see `assert_asked/2`) so far."
  defmacro refute_asked(method, params \\ quote(do: _)) do
    quote do
      require ExUnit.Assertions

      ExUnit.Assertions.refute_received(
        {:sake_test_asked, %{"method" => unquote(method), "params" => unquote(params)}}
      )
    end
  end

  @doc """
  Asserts that a server `listen/2` follows broadcast a change of its list
  of `:tools`, `:resources` or `:prompts` (`Sake.Server.notify_list_changed/2`).
  """
  defmacro assert_list_changed(kind) do
    quote do
      require ExUnit.Assertions

      ExUnit.Assertions.assert_receive(
        {:sake_test_broadcast, _server, {:list_changed, unquote(kind)}}
      )
    end
  end

  @doc "Refutes that such a change (see `assert_list_changed/1`) was broadcast so far."
  defmacro refute_list_changed(kind) do
    quote do
      require ExUnit.Assertions

      ExUnit.Assertions.refute_received(
        {:sake_test_broadcast, _server, {:list_changed, unquote(kind)}}
      )
    end
  end

  @doc """
  Asserts that a server `listen/2` follows broadcast a change of the
  resource at `uri` (`Sake.Server.resource_updated/2`). `uri` is a
  pattern.
  """
  defmacro assert_resource_updated(uri) do
    quote do
      require ExUnit.Assertions

      ExUnit.Assertions.assert_receive(
        {:sake_test_broadcast, _server, {:resource_updated, unquote(uri)}}
      )
    end
  end

  @doc "Refutes that such a change (see `assert_resource_updated/1`) was broadcast so far."
  defmacro refute_resource_updated(uri) do
    quote do
      require ExUnit.Assertions

      ExUnit.Assertions.refute_received(
        {:sake_test_broadcast, _server, {:resource_updated, unquote(uri)}}
      )
    end
  end
end
