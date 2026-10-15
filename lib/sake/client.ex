defmodule Sake.Client do
  @moduledoc """
  A client for MCP servers over Streamable HTTP or stdio, on both protocol
  eras.

      {:ok, session} = Sake.Client.connect("https://mcp.example.com/mcp", headers: [{"authorization", "Bearer ..."}])
      {:ok, tools, session} = Sake.Client.list_tools(session)
      {:ok, result, session} = Sake.Client.call_tool(session, "search", %{"query" => "x"})

  The client is functional: every call returns the updated session. Pass
  `on_input:` to answer elicitation requests, `sampling:` to answer
  sampling requests (`fn params, session -> {:ok, result} | {:error,
  error} end`), `roots:` to share roots (a list of `%{"uri" => ...,
  "name" => ...}` maps, or a function of the session that returns one),
  `on_notification:` (a function of a method and its params) to see the
  progress and log notifications of a call, and `auth:` to have the client
  run the MCP authorization flow itself on a 401 (see `Sake.Client.Auth`);
  without it, a 401 comes back as
  `{:error, {:unauthorized, %Sake.Client.Challenge{}}}`.

  On the modern protocol the client declares the tasks extension, so a
  server may answer a tool call with a task; `call_tool/3` follows it to
  the end (`task_timeout:`, in ms, default five minutes), and
  `call_tool_async/3` hands it back instead. `tasks: false` leaves the
  extension out.

  `{:stdio, command, args}` in place of a URL launches the server as a
  subprocess and talks to it over its standard input and output:

      {:ok, session} = Sake.Client.connect({:stdio, "npx", ["-y", "@modelcontextprotocol/server-everything"]})

  Stdio options: `env:` (a map or list of name-value pairs; a `nil` value
  unsets the variable), `cd:`, `stderr:` (`:inherit`, the default, shares
  this VM's standard error; `:ignore` discards it), `probe_timeout:` (ms
  to wait for an answer to the modern probe before falling back to
  `initialize`, default 10 000), `close_timeout:` (ms `close/1` waits for
  the server to exit before killing it, default 5 000).
  """

  require Logger

  alias Sake.Client.{Auth, Inputs, Session, ToolResult, Transport}
  alias Sake.{Content, JSONRPC, Protocol, Schema}

  # The errors only a modern server sends; a legacy server answers the
  # `server/discover` probe with "method not found" (-32601) or "invalid
  # params" (-32602), or with no JSON-RPC body at all.
  @modern_errors [-32_020, -32_021, -32_022]
  @legacy_errors [-32_601, -32_602]
  @max_retries 3
  @tasks_extension "io.modelcontextprotocol/tasks"
  @probe_timeout 10_000

  # A probe that ends in one of these was answered by a modern server, or
  # needs authorizing whatever the era: no legacy handshake follows.
  @final_probe_errors [:no_common_version, :unauthorized, :insufficient_scope, :auth]

  # How many times one request may run the authorization flow (a 401, then
  # a step-up on a 403) before the error goes back to the caller.
  @max_authorizations 2

  @spec connect(String.t() | {:stdio, String.t(), [String.t()]}, keyword()) ::
          {:ok, Session.t()} | {:error, term()}
  def connect(target, opts \\ [])

  def connect({:stdio, command, args}, opts) do
    with {:ok, pid} <- Sake.Client.Stdio.start(command, args, opts) do
      case open(%{build_session(nil, opts) | stdio: pid}, opts) do
        {:ok, session} ->
          {:ok, session}

        error ->
          Sake.Client.Stdio.close(pid)
          error
      end
    end
  end

  def connect(url, opts), do: open(build_session(url, opts), opts)

  defp open(session, opts) do
    legacy_version = opts[:legacy_version] || hd(Protocol.legacy())

    case opts[:era] do
      :modern ->
        case modern_connect(modern(session)) do
          {:ok, session} -> {:ok, session}
          {:error, reason, _session} -> {:error, reason}
        end

      :legacy ->
        legacy_connect(%{session | era: :legacy}, legacy_version)

      nil ->
        probe(session, legacy_version, opts)
    end
  end

  defp build_session(url, opts) do
    client_info = opts[:client_info] || %{"name" => "Sake", "version" => Sake.version()}
    req = opts[:req] || []

    %Session{
      url: url,
      headers: opts[:headers] || [],
      client_info: client_info,
      capabilities: opts[:capabilities] || default_capabilities(opts),
      on_input: opts[:on_input],
      sampling: opts[:sampling],
      roots: opts[:roots],
      on_notification: opts[:on_notification],
      tasks: Keyword.get(opts, :tasks, true),
      task_timeout: opts[:task_timeout] || 300_000,
      # There is no HTTP authorization on stdio: the server takes its
      # credentials from its environment.
      auth:
        url && opts[:auth] &&
          Auth.new(url, opts[:auth], client_name: client_info["name"], req: req),
      req: req
    }
  end

  # A client claims only what it can answer: each answering option turns
  # on its own capability.
  defp default_capabilities(opts) do
    %{}
    |> put_capability(opts[:on_input], "elicitation", %{})
    |> put_capability(opts[:sampling], "sampling", %{})
    |> put_capability(opts[:roots], "roots", %{"listChanged" => false})
  end

  defp put_capability(caps, nil, _name, _value), do: caps
  defp put_capability(caps, _option, name, value), do: Map.put(caps, name, value)

  defp modern(session), do: %{session | era: :modern, revision: Protocol.modern()}

  # The probe's session goes on to the legacy handshake: a token the probe
  # obtained is not thrown away with it, so the person authorizes once.
  defp legacy(session), do: %{session | era: :legacy, revision: nil, session_id: nil}

  # An unsupported-version answer that lists the very revision the client
  # sent is not a verdict on that revision (a server mid-deploy, or an
  # intermediary that answered for it), and the specification asks a
  # client to retry with a mutually supported version: the probe tries
  # once more. Otherwise there is nothing to retry with, since Sake
  # speaks a single modern revision.
  defp probe(session, legacy_version, opts, retried? \\ false) do
    case probe_once(session, legacy_version, opts) do
      {:error, {:no_common_version, supported}} = error ->
        if not retried? and Protocol.modern() in supported,
          do: probe(session, legacy_version, opts, true),
          else: error

      other ->
        other
    end
  end

  # Over stdio a legacy server answers the probe with whatever error it
  # likes, or not at all (the stdio transport's "Backward Compatibility"):
  # only an error a modern server sends keeps the client modern. The
  # session a failed probe returns has used the probe's id, so a late
  # answer to it can never be taken for the answer to `initialize`.
  defp probe_once(%Session{stdio: pid} = session, legacy_version, opts) when is_pid(pid) do
    timeout = opts[:probe_timeout] || @probe_timeout

    case modern_connect(modern(session), timeout: timeout) do
      {:ok, session} ->
        {:ok, session}

      {:error, {:no_common_version, _} = e, _session} ->
        {:error, e}

      {:error, {:rpc, %{"code" => code} = error}, _session} when code in @modern_errors ->
        {:error, {:rpc, error}}

      {:error, {:rpc, _error}, session} ->
        legacy_connect(legacy(session), legacy_version)

      {:error, :timeout, session} ->
        legacy_connect(legacy(session), legacy_version)

      {:error, reason, _session} ->
        {:error, reason}
    end
  end

  defp probe_once(session, legacy_version, _opts) do
    case modern_connect(modern(session)) do
      {:ok, session} ->
        {:ok, session}

      {:error, {kind, _} = e, _session} when kind in @final_probe_errors ->
        {:error, e}

      {:error, {:rpc, %{"code" => code} = error}, _session} when code in @modern_errors ->
        {:error, {:rpc, error}}

      {:error, {:rpc, %{"code" => code}}, session} when code in @legacy_errors ->
        legacy_connect(legacy(session), legacy_version)

      {:error, {:http, _status, body}, session} ->
        handle_probe_http_error(body, legacy(session), legacy_version)

      {:error, reason, _session} ->
        {:error, reason}
    end
  end

  # A `4xx` with a JSON-RPC error body from a modern server: `-32022` means
  # the client's revision is unsupported (see `probe/3` for the one retry);
  # the other modern error codes are reported as-is; anything else
  # (-32601, -32602, or no recognisable error body) means legacy.
  defp handle_probe_http_error(
         %{"error" => %{"code" => -32_022, "data" => %{"supported" => supported}}},
         _session,
         _legacy_version
       ) do
    {:error, {:no_common_version, supported}}
  end

  defp handle_probe_http_error(body, session, legacy_version)
       when is_map(body) and is_map_key(body, "error") do
    if body["error"]["code"] in @modern_errors,
      do: {:error, {:rpc, body["error"]}},
      else: legacy_connect(session, legacy_version)
  end

  defp handle_probe_http_error(_body, session, legacy_version),
    do: legacy_connect(session, legacy_version)

  defp modern_connect(session, opts \\ []) do
    case request(session, "server/discover", %{}, opts) do
      {:ok, result, session} ->
        supported = result["supportedVersions"] || [Protocol.modern()]

        case Enum.find(supported, &(&1 == Protocol.modern())) do
          nil ->
            {:error, {:no_common_version, supported}, session}

          version ->
            {:ok,
             %{
               session
               | revision: version,
                 server_capabilities: result["capabilities"] || %{},
                 instructions: result["instructions"],
                 server_info: get_in(result, ["_meta", Protocol.meta(:server_info)])
             }}
        end

      {:error, {:rpc, %{"code" => -32_022, "data" => %{"supported" => supported}}}, session} ->
        {:error, {:no_common_version, supported}, session}

      {:error, reason, session} ->
        {:error, reason, session}
    end
  end

  defp legacy_connect(session, version) do
    params = %{
      "protocolVersion" => version,
      "capabilities" => session.capabilities,
      "clientInfo" => session.client_info
    }

    with {:ok, result, session} <- request(session, "initialize", params),
         {:ok, :accepted, session} <-
           post(session, JSONRPC.notification("notifications/initialized"), []) do
      {:ok,
       %{
         session
         | revision: result["protocolVersion"],
           server_capabilities: result["capabilities"] || %{},
           server_info: result["serverInfo"],
           instructions: result["instructions"]
       }}
    else
      {:error, reason, _} -> {:error, reason}
      {:ok, _other, _} -> {:error, :bad_initialized_ack}
    end
  end

  # ---- calls

  @spec discover(Session.t()) :: {:ok, map(), Session.t()} | {:error, term(), Session.t()}
  def discover(session), do: request(session, "server/discover", %{})

  @spec ping(Session.t()) :: {:ok, Session.t()} | {:error, term(), Session.t()}
  def ping(%Session{era: :legacy} = session) do
    with {:ok, _, session} <- request(session, "ping", %{}), do: {:ok, session}
  end

  def ping(session) do
    with {:ok, _, session} <- discover(session), do: {:ok, session}
  end

  @spec list_tools(Session.t()) ::
          {:ok, [Sake.Tool.Spec.t()], Session.t()} | {:error, term(), Session.t()}
  def list_tools(session) do
    with {:ok, result, session} <- paged(session, "tools/list", "tools") do
      specs = result |> Enum.map(&tool_spec/1) |> Enum.reject(&is_nil/1)
      {:ok, specs, %{session | tools: Map.new(specs, &{&1.name, &1})}}
    end
  end

  @doc """
  Calls a tool and returns its result. When the server answers with a task
  (see `Sake.Tasks`), the call polls it to the end, answering its input
  requests as a retry would, and returns the final result: a failed task
  is `{:error, {:rpc, error}, session}`, a cancelled one `{:error,
  :cancelled, session}`, and one still running after `task_timeout:` is
  cancelled and returned as `{:error, :task_timeout, session}`.
  """
  @spec call_tool(Session.t(), String.t(), map()) ::
          {:ok, ToolResult.t(), Session.t()} | {:error, term(), Session.t()}
  def call_tool(session, name, arguments) do
    with {:ok, result, session} <- tools_call(session, name, arguments),
         {:ok, result, session} <- await_task(session, result) do
      {:ok, tool_result(result), session}
    end
  end

  @doc """
  Calls a tool and returns at once: the result, or `{:task, task}` when the
  server made a task of the call. Follow the task with `get_task/2`,
  answer its `inputRequests` with `update_task/3`, and stop it with
  `cancel_task/2`.
  """
  @spec call_tool_async(Session.t(), String.t(), map()) ::
          {:ok, ToolResult.t() | {:task, map()}, Session.t()} | {:error, term(), Session.t()}
  def call_tool_async(session, name, arguments) do
    case tools_call(session, name, arguments) do
      {:ok, %{"resultType" => "task"} = task, session} -> {:ok, {:task, task}, session}
      {:ok, result, session} -> {:ok, tool_result(result), session}
      error -> error
    end
  end

  @doc "The task as the server has it now: its status, and `inputRequests`, `result` or `error`."
  @spec get_task(Session.t(), String.t()) ::
          {:ok, map(), Session.t()} | {:error, term(), Session.t()}
  def get_task(session, task_id), do: request(session, "tasks/get", %{"taskId" => task_id})

  @doc "Answers some or all of a task's `inputRequests`, by key."
  @spec update_task(Session.t(), String.t(), map()) ::
          {:ok, Session.t()} | {:error, term(), Session.t()}
  def update_task(session, task_id, responses) do
    params = %{"taskId" => task_id, "inputResponses" => responses}
    with {:ok, _, session} <- request(session, "tasks/update", params), do: {:ok, session}
  end

  @doc "Asks the server to cancel a task. Cancellation is cooperative: the task may still end otherwise."
  @spec cancel_task(Session.t(), String.t()) :: {:ok, Session.t()} | {:error, term(), Session.t()}
  def cancel_task(session, task_id) do
    with {:ok, _, session} <- request(session, "tasks/cancel", %{"taskId" => task_id}),
         do: {:ok, session}
  end

  defp tools_call(session, name, arguments) do
    request(session, "tools/call", %{"name" => name, "arguments" => arguments},
      tool: session.tools[name]
    )
  end

  defp tool_result(result) do
    content =
      result["content"]
      |> List.wrap()
      |> Enum.map(&Content.from_wire/1)
      |> Enum.reject(&match?({:error, _}, &1))

    text = content |> Enum.filter(&(&1.type == :text)) |> Enum.map_join("\n", & &1.text)

    %ToolResult{
      content: content,
      structured: result["structuredContent"],
      is_error: result["isError"] == true,
      text: text,
      meta: result["_meta"] || %{}
    }
  end

  @spec list_resources(Session.t()) :: {:ok, [map()], Session.t()} | {:error, term(), Session.t()}
  def list_resources(session), do: paged(session, "resources/list", "resources")

  @spec list_resource_templates(Session.t()) ::
          {:ok, [map()], Session.t()} | {:error, term(), Session.t()}
  def list_resource_templates(session),
    do: paged(session, "resources/templates/list", "resourceTemplates")

  @spec read_resource(Session.t(), String.t()) ::
          {:ok, [Content.t()], Session.t()} | {:error, term(), Session.t()}
  def read_resource(session, uri) do
    with {:ok, result, session} <- request(session, "resources/read", %{"uri" => uri}) do
      contents =
        result["contents"]
        |> List.wrap()
        |> Enum.map(&Content.from_wire(%{"type" => "resource", "resource" => &1}))
        |> Enum.reject(&match?({:error, _}, &1))

      {:ok, contents, session}
    end
  end

  @spec list_prompts(Session.t()) :: {:ok, [map()], Session.t()} | {:error, term(), Session.t()}
  def list_prompts(session), do: paged(session, "prompts/list", "prompts")

  @spec get_prompt(Session.t(), String.t(), map()) ::
          {:ok, map(), Session.t()} | {:error, term(), Session.t()}
  def get_prompt(session, name, arguments),
    do: request(session, "prompts/get", %{"name" => name, "arguments" => arguments})

  @spec complete(
          Session.t(),
          {:prompt, String.t()} | {:resource, String.t()},
          String.t(),
          String.t()
        ) :: {:ok, map(), Session.t()} | {:error, term(), Session.t()}
  def complete(session, ref, argument, value) do
    ref =
      case ref do
        {:prompt, n} -> %{"type" => "ref/prompt", "name" => n}
        {:resource, u} -> %{"type" => "ref/resource", "uri" => u}
      end

    with {:ok, result, session} <-
           request(session, "completion/complete", %{
             "ref" => ref,
             "argument" => %{"name" => argument, "value" => value}
           }) do
      {:ok, result["completion"] || %{}, session}
    end
  end

  @spec close(Session.t()) :: :ok
  def close(%Session{stdio: pid}) when is_pid(pid), do: Sake.Client.Stdio.close(pid)

  def close(%Session{era: :legacy, session_id: sid} = session) when is_binary(sid),
    do: Transport.delete(session)

  def close(_session), do: :ok

  # ---- the request loop (pagination, MRTR retries)

  @max_pages 1000

  defp paged(session, method, key, cursor \\ nil, acc \\ [], page \\ 0) do
    params = if cursor, do: %{"cursor" => cursor}, else: %{}

    with {:ok, result, session} <- request(session, method, params) do
      items = acc ++ List.wrap(result[key])
      next_page(result["nextCursor"], cursor, page, session, method, key, items)
    end
  end

  defp next_page(nil, _cursor, _page, session, _method, _key, items), do: {:ok, items, session}

  defp next_page(next, cursor, _page, session, _method, _key, _items) when next == cursor,
    do: {:error, :pagination_loop, session}

  defp next_page(_next, _cursor, page, session, _method, _key, _items)
       when page + 1 >= @max_pages,
       do: {:error, :pagination_loop, session}

  defp next_page(next, _cursor, page, session, method, key, items),
    do: paged(session, method, key, next, items, page + 1)

  defp request(session, method, params, opts \\ [], attempt \\ 0) do
    id = session.next_id
    session = %{session | next_id: id + 1}

    params =
      if session.era == :modern or session.era == nil,
        do: Map.put(params, "_meta", meta(session)),
        else: params

    params = progress_token(params, session, id)

    case post(session, JSONRPC.request(id, method, params), opts) do
      {:ok, %{"result" => %{"resultType" => "input_required"} = result}, session}
      when attempt < @max_retries ->
        retry_with_inputs(session, method, params, result, opts, attempt)

      {:ok, %{"result" => result}, session} ->
        {:ok, result, session}

      {:ok, %{"error" => error}, session} ->
        {:error, {:rpc, error}, session}

      {:ok, :accepted, session} ->
        {:ok, %{}, session}

      {:error, reason, session} ->
        {:error, reason, session}
    end
  end

  # ---- authorization

  # One message, with the session's token when it has one. A 401 runs the
  # authorization flow (the refresh token first, the first time), a 403
  # `insufficient_scope` a step-up; either way the same message is sent
  # again with the new token. The JSON-RPC id stays the same: the server
  # refused the request at the HTTP level, so it never saw that id.
  defp post(session, message, opts, authorizations \\ 0) do
    session = if session.auth, do: %{session | auth: Auth.fresh(session.auth)}, else: session

    case Transport.post(session, message, opts) do
      {:error, {:unauthorized, challenge} = error}
      when session.auth != nil and authorizations < @max_authorizations ->
        session
        |> reauthorize(error, &Auth.unauthorized(&1, challenge, authorizations == 0))
        |> retry(message, opts, authorizations)

      {:error, {:insufficient_scope, challenge} = error}
      when session.auth != nil and authorizations < @max_authorizations ->
        session
        |> reauthorize(error, &Auth.insufficient_scope(&1, challenge))
        |> retry(message, opts, authorizations)

      {:error, reason} ->
        {:error, reason, session}

      {:ok, result, session} ->
        {:ok, result, session}
    end
  end

  defp reauthorize(session, error, fun) do
    case fun.(session.auth) do
      {:ok, auth} -> {:ok, %{session | auth: auth}}
      {:error, reason, auth} -> {:error, {:auth, reason}, %{session | auth: auth}}
      :exhausted -> {:error, error, session}
    end
  end

  defp retry({:ok, session}, message, opts, authorizations),
    do: post(session, message, opts, authorizations + 1)

  defp retry(error, _message, _opts, _authorizations), do: error

  # Only answers go back: a request nothing could answer (a sampling or
  # roots request without `sampling:` or `roots:`) is left out, and the
  # server asks again or carries on without it.
  defp retry_with_inputs(session, method, params, result, opts, attempt) do
    responses =
      for {key, {:ok, answer}} <- Inputs.answer(session, result["inputRequests"] || %{}),
          into: %{},
          do: {key, answer}

    retry =
      params
      |> Map.delete("_meta")
      |> Map.put("inputResponses", responses)
      |> put_request_state(result["requestState"])

    request(session, method, retry, opts, attempt + 1)
  end

  defp put_request_state(params, nil), do: params
  defp put_request_state(params, state), do: Map.put(params, "requestState", state)

  # A client that takes notifications asks for progress on every request,
  # under the request's own id.
  defp progress_token(params, %Session{on_notification: nil}, _id), do: params

  defp progress_token(params, _session, id),
    do: Map.update(params, "_meta", %{"progressToken" => id}, &Map.put(&1, "progressToken", id))

  defp meta(session) do
    %{
      Protocol.meta(:protocol_version) => session.revision || Protocol.modern(),
      Protocol.meta(:client_info) => session.client_info,
      Protocol.meta(:client_capabilities) => modern_capabilities(session)
    }
  end

  # The tasks extension is modern only, so it is declared per request
  # rather than in the capabilities a legacy `initialize` sends.
  defp modern_capabilities(%Session{tasks: false} = session), do: session.capabilities

  defp modern_capabilities(session) do
    Map.update(
      session.capabilities,
      "extensions",
      %{@tasks_extension => %{}},
      &Map.put_new(&1, @tasks_extension, %{})
    )
  end

  # ---- tasks: a call the server made a task of is polled to the end

  defp await_task(%Session{tasks: true} = session, %{"resultType" => "task"} = task) do
    deadline = System.monotonic_time(:millisecond) + session.task_timeout
    follow(session, task, deadline, %{})
  end

  # A server must not answer with a task a client that did not declare
  # the extension.
  defp await_task(session, %{"resultType" => "task"} = task),
    do: {:error, {:unexpected_task, task}, session}

  defp await_task(session, result), do: {:ok, result, session}

  # `asked` holds the input request keys already handled, so a request
  # still listed on the next poll (the server applies an update
  # eventually) is not answered twice.
  defp follow(session, %{"status" => "completed"} = task, _deadline, _asked),
    do: {:ok, task["result"] || %{}, session}

  defp follow(session, %{"status" => "failed"} = task, _deadline, _asked),
    do: {:error, {:rpc, task["error"]}, session}

  defp follow(session, %{"status" => "cancelled"}, _deadline, _asked),
    do: {:error, :cancelled, session}

  defp follow(session, %{"status" => "input_required"} = task, deadline, asked) do
    requests = Map.drop(task["inputRequests"] || %{}, Map.keys(asked))

    responses =
      for {key, {:ok, answer}} <- Inputs.answer(session, requests), into: %{}, do: {key, answer}

    asked = Map.merge(asked, Map.new(requests, fn {key, _} -> {key, true} end))

    if responses == %{} do
      poll(session, task, deadline, asked)
    else
      with {:ok, session} <- update_task(session, task["taskId"], responses),
           do: poll(session, task, deadline, asked)
    end
  end

  defp follow(session, task, deadline, asked), do: poll(session, task, deadline, asked)

  defp poll(session, task, deadline, asked) do
    left = deadline - System.monotonic_time(:millisecond)

    if left <= 0 do
      _ = cancel_task(session, task["taskId"])
      {:error, :task_timeout, session}
    else
      Process.sleep(min(task["pollIntervalMs"] || 1_000, left))

      with {:ok, task, session} <- get_task(session, task["taskId"]),
           do: follow(session, task, deadline, asked)
    end
  end

  # ---- tool definitions from the wire

  defp tool_spec(%{"name" => name} = t) do
    schema = t["inputSchema"] || %{"type" => "object"}

    case check_headers(schema, Schema.header_entries(schema)) do
      :ok ->
        %Sake.Tool.Spec{
          module: nil,
          name: name,
          title: t["title"],
          description: t["description"],
          icons: t["icons"] || [],
          input_schema: schema,
          output_schema: t["outputSchema"],
          annotations: t["annotations"] || %{},
          meta: t["_meta"],
          headers: Schema.header_paths(schema)
        }

      {:error, reason} ->
        Logger.warning(
          "Sake.Client dropped tool #{inspect(name)}: invalid x-mcp-header (#{reason})"
        )

        nil
    end
  end

  defp tool_spec(_), do: nil

  defp check_headers(schema, headers) do
    names = Enum.map(headers, fn {n, _} -> String.downcase(n) end)

    headers
    |> Enum.reduce_while(:ok, fn {name, path}, :ok ->
      prop = get_in(schema, Enum.flat_map(path, &["properties", &1])) || %{}

      cond do
        not Schema.valid_header_name?(name) ->
          {:halt, {:error, "bad name #{inspect(name)}"}}

        prop["type"] not in ["string", "integer", "boolean"] ->
          {:halt, {:error, "#{Enum.join(path, ".")} is not a string, integer or boolean"}}

        true ->
          {:cont, :ok}
      end
    end)
    |> case do
      :ok ->
        if length(Enum.uniq(names)) == length(names), do: :ok, else: {:error, "duplicate names"}

      error ->
        error
    end
  end
end
