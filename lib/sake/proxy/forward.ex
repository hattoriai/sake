defmodule Sake.Proxy.Forward do
  @moduledoc false
  # A proxied component's request, forwarded to the upstream with the
  # principal's session (`Sake.Proxy.Upstream`), and the upstream's answer
  # made the proxy's own. `Sake.Server.Dispatch` calls here for a spec with
  # a `proxy`, after its own checks and the middleware's `before_` events,
  # and gets what it would get from a local component.
  #
  # Questions travel both ways and across eras, through `Sake.Server.Ask`,
  # the path a local component's questions take:
  #
  #   * A modern upstream answers `input_required`. Each of its
  #     `inputRequests` is asked of the proxy's client: a legacy client on
  #     its stream, a task's client through the task, and a modern client
  #     by answering `input_required` in turn, with a `requestState` that
  #     carries the upstream's, signed and bound to the principal. The
  #     answers go back upstream on the retry, with its `requestState`.
  #   * A legacy upstream asks on the call's stream. A legacy client or a
  #     task is asked and answered while the upstream waits; a modern
  #     client cannot answer within the call, so the call is abandoned
  #     (the upstream sees its stream dropped) and the client gets the
  #     question; on its retry the call runs again upstream, and the
  #     question, asked again, is answered from the retry. As with a local
  #     component on the modern protocol, the upstream tool runs once per
  #     round: it must ask before it acts.

  require Logger

  alias Sake.{Context, JSONRPC, Progress, Protocol}
  alias Sake.Proxy.Upstream
  alias Sake.Server.{Ask, Mount}

  # Where a proxied call keeps the upstream's `requestState` and the keys
  # it asked, inside the proxy's own signed request state. Keys with this
  # prefix are never taken from a client's `inputResponses`.
  @state "ai.hattori.sake/upstream"
  @vendor_key "ai.hattori.sake/key"
  @max_rounds 8
  @asks %{
    "elicitation/create" => "elicitation",
    "sampling/createMessage" => "sampling",
    "roots/list" => "roots"
  }
  @levels ~w(debug info notice warning error critical alert emergency)

  @type outcome ::
          {:ok, map()}
          | {:error, integer(), String.t()}
          | {:error, integer(), String.t(), map()}

  # ---- tools/call

  @doc """
  Calls the tool upstream: its result, or `{:task, task}` when the
  upstream made a task of the call (only ever for a client that takes
  tasks: the proxy declares the extension upstream only then).
  """
  @spec call_tool(struct(), map(), Context.t()) :: outcome() | {:task, map()}
  def call_tool(spec, args, ctx) do
    inner = Mount.innermost(spec)
    params = %{"name" => inner.name, "arguments" => args}

    case request(spec.proxy, "tools/call", params, ctx, tool: inner) do
      {:ok, %{"resultType" => "task", "taskId" => id} = task} when is_binary(id) ->
        if tasks?(ctx), do: {:task, task}, else: unexpected_task()

      {:ok, result} ->
        {:ok, tool_result(result)}

      error ->
        error
    end
  end

  defp unexpected_task,
    do: {:error, JSONRPC.code(:internal), "The upstream server answered with a task."}

  # The result as Sake's own tools give it: what an upstream adds beyond a
  # `CallToolResult` (its server info, a `resultType`) stays behind.
  defp tool_result(result) do
    %{
      "content" => result |> Map.get("content") |> List.wrap() |> Enum.filter(&is_map/1),
      "isError" => result["isError"] == true
    }
    |> put_some("structuredContent", map(result["structuredContent"]))
    |> put_some("_meta", meta(result["_meta"]))
  end

  # ---- resources/read

  @doc "Reads the resource upstream: its result and the upstream's `ttlMs`, if any."
  @spec read(struct(), String.t(), Context.t()) ::
          {:ok, map(), pos_integer() | nil} | {:error, :not_found} | outcome()
  def read(spec, uri, ctx) do
    {:ok, inner} = Mount.inner_uri(spec, uri)

    case request(spec.proxy, "resources/read", %{"uri" => inner}, ctx, []) do
      {:ok, result} ->
        ttl = if is_integer(result["ttlMs"]) and result["ttlMs"] > 0, do: result["ttlMs"]

        {:ok,
         put_some(%{"contents" => contents(result["contents"])}, "_meta", meta(result["_meta"])),
         ttl}

      # The upstream's not-found names its own URI; the client is told of
      # the one it asked for.
      {:error, code, _message, _data} when code in [-32_602, -32_002] ->
        {:error, :not_found}

      {:error, code, _message} when code in [-32_602, -32_002] ->
        {:error, :not_found}

      error ->
        error
    end
  end

  defp contents(contents) when is_list(contents) do
    for %{"uri" => uri} = content <- contents,
        is_binary(uri) and (is_binary(content["text"]) or is_binary(content["blob"])),
        do: Map.take(content, ["uri", "mimeType", "text", "blob", "_meta"])
  end

  defp contents(_contents), do: []

  # ---- prompts/get

  @doc "Gets the prompt upstream."
  @spec get_prompt(struct(), map(), Context.t()) :: outcome()
  def get_prompt(spec, args, ctx) do
    params = %{"name" => Mount.innermost(spec).name, "arguments" => args}

    with {:ok, result} <- request(spec.proxy, "prompts/get", params, ctx, []) do
      messages =
        for %{"role" => role, "content" => %{} = content} <- List.wrap(result["messages"]),
            role in ["user", "assistant"],
            do: %{"role" => role, "content" => content}

      {:ok, put_some(%{"messages" => messages}, "description", string(result["description"]))}
    end
  end

  # ---- completion/complete

  @doc "Completes an argument of the prompt or resource template upstream; nothing when it cannot."
  @spec complete(struct(), String.t(), String.t(), Context.t()) :: {:ok, map()}
  def complete(spec, arg, value, ctx) do
    inner = Mount.innermost(spec)

    ref =
      case inner do
        %Sake.Prompt.Spec{name: name} -> %{"type" => "ref/prompt", "name" => name}
        %Sake.Resource.Spec{uri: uri} -> %{"type" => "ref/resource", "uri" => uri}
      end

    params = %{"ref" => ref, "argument" => %{"name" => arg, "value" => value}}

    case request(spec.proxy, "completion/complete", params, ctx, []) do
      {:ok, %{"completion" => %{} = completion}} ->
        {:ok, %{"completion" => completion(completion)}}

      _ ->
        {:ok, %{"completion" => %{"values" => [], "hasMore" => false}}}
    end
  end

  defp completion(completion) do
    %{
      "values" =>
        completion
        |> Map.get("values")
        |> List.wrap()
        |> Enum.filter(&is_binary/1)
        |> Enum.take(100),
      "hasMore" => completion["hasMore"] == true
    }
    |> put_some("total", if(is_integer(completion["total"]), do: completion["total"]))
  end

  # ---- the request, with its rounds of questions

  defp request(proxy, method, params, ctx, opts, round \\ 0) do
    params = if round == 0, do: resume(params, ctx), else: params

    case Upstream.call(proxy, ctx, &Sake.Client.request(prepare(&1, ctx), method, params, opts)) do
      {:ok, %{"resultType" => "input_required"} = result} when round < @max_rounds ->
        state = string(result["requestState"])
        responses = ask(ctx, input_requests(result["inputRequests"]), state)

        params
        |> Map.put("inputResponses", responses)
        |> put_state(state)
        |> then(&request(proxy, method, &1, ctx, opts, round + 1))

      {:ok, %{"resultType" => "input_required"}} ->
        {:error, JSONRPC.code(:internal), "The upstream server kept asking for input."}

      {:ok, %{} = result} ->
        {:ok, result}

      {:ok, _other} ->
        {:error, JSONRPC.code(:internal), "The upstream server sent no result."}

      {:error, reason} ->
        error(proxy, reason)
    end
  end

  # A client's retry carries the answers to the upstream's questions, and,
  # in the proxy's signed request state, the upstream's own state and
  # which questions it asked.
  defp resume(params, %Context{inputs: %{@state => %{"keys" => keys} = upstream} = inputs}) do
    params
    |> Map.put("inputResponses", Map.take(inputs, keys))
    |> put_state(upstream["state"])
  end

  defp resume(params, _ctx), do: params

  defp put_state(params, nil), do: Map.delete(params, "requestState")
  defp put_state(params, state), do: Map.put(params, "requestState", state)

  # The upstream's questions that are questions: a key Sake reserves, or
  # a method the proxy cannot pass on, is left out.
  defp input_requests(%{} = requests) do
    for {key, %{"method" => method} = request} <- requests,
        is_binary(key) and byte_size(key) <= 256 and
          not String.starts_with?(key, "ai.hattori.sake/"),
        Map.has_key?(@asks, method),
        into: %{},
        do: {key, %{"method" => method, "params" => map(request["params"]) || %{}}}
  end

  defp input_requests(_requests), do: %{}

  # Each question as a local component's would be asked (see the module
  # notes): all at once, and a modern client's unanswered ones together,
  # with the upstream's state.
  defp ask(_ctx, requests, _state) when requests == %{}, do: %{}

  defp ask(ctx, requests, state) do
    funs = for {key, request} <- requests, do: &ask_one(&1, key, request)

    answers =
      try do
        Sake.Input.all(ctx, funs)
      catch
        :throw, {:sake_input_required, pending} ->
          throw(
            {:sake_input_required, pending,
             %{@state => %{"state" => state, "keys" => Map.keys(requests)}}}
          )
      end

    for {key, answer} <- answers, answer != nil, into: %{}, do: {key, answer}
  end

  defp ask_one(ctx, key, %{"method" => method, "params" => params}) do
    case Ask.request(ctx, @asks[method], key, method, params) do
      {:ok, answer} -> {key, answer}
      {:error, _reason} -> {key, unanswered(method)}
    end
  end

  # A question the client could not answer: an elicitation is cancelled,
  # anything else goes unanswered, and the upstream carries on without
  # it or asks again.
  defp unanswered("elicitation/create"), do: %{"action" => "cancel"}
  defp unanswered(_method), do: nil

  # ---- the session, for one call

  # The upstream sees the proxy's client: its capabilities and log level
  # (per request on the modern protocol; a legacy session declared all it
  # can pass on when it opened), the tasks extension when the client takes
  # tasks, and the questions and notifications go back to it.
  defp prepare(session, ctx) do
    modern? = session.era == :modern

    %{
      session
      | capabilities: if(modern?, do: capabilities(ctx), else: session.capabilities),
        log_level: if(modern?, do: ctx.log_level, else: session.log_level),
        tasks: tasks?(ctx),
        on_notification: &notify(ctx, &1, &2),
        on_input: fn requests, _session -> legacy_elicit(ctx, requests) end,
        sampling: fn params, _session -> legacy_sample(ctx, params) end,
        roots: fn _session -> legacy_roots(ctx) end
    }
  end

  defp capabilities(ctx) do
    caps = Map.take(ctx.client_capabilities, ["elicitation", "sampling", "roots"])

    if Sake.UI.supported?(ctx),
      do: Map.put(caps, "extensions", Sake.UI.client_capability()),
      else: caps
  end

  defp tasks?(%Context{task: nil} = ctx),
    do: Sake.Server.Tasks.declared?(ctx) and Sake.Tasks.running?()

  defp tasks?(_ctx), do: false

  defp notify(ctx, "notifications/progress", %{"progress" => progress} = params)
       when is_number(progress) do
    total = if is_number(params["total"]), do: params["total"]
    Progress.report(ctx, progress, total, string(params["message"]))
  end

  defp notify(ctx, "notifications/message", %{"level" => level} = params) when level in @levels,
    do: Progress.log(ctx, String.to_existing_atom(level), params["data"])

  defp notify(_ctx, _method, _params), do: :ok

  # A legacy upstream's questions, asked on the call's stream. The key is
  # the one a Sake upstream names, else one the question itself gives, so
  # that the same question asked again on a retry finds its answer.
  defp legacy_elicit(ctx, requests) do
    Map.new(requests, fn {key, %{"method" => method, "params" => params}} ->
      {_key, answer} =
        ask_one(ctx, legacy_key(key, method, params), %{"method" => method, "params" => params})

      {key, answer}
    end)
  end

  defp legacy_sample(ctx, params) do
    key = legacy_key("legacy", "sampling/createMessage", params)

    case ask_one(ctx, key, %{"method" => "sampling/createMessage", "params" => params}) do
      {_key, %{} = answer} ->
        {:ok, answer}

      {_key, nil} ->
        {:error,
         %{"code" => JSONRPC.code(:invalid_request), "message" => "Sampling is not available."}}
    end
  end

  defp legacy_roots(ctx) do
    case ask_one(ctx, "upstream:roots", %{"method" => "roots/list", "params" => %{}}) do
      {_key, %{"roots" => roots}} when is_list(roots) -> roots
      _ -> []
    end
  end

  defp legacy_key("legacy", method, params) do
    case params do
      %{"_meta" => %{@vendor_key => key}} when is_binary(key) ->
        key

      _ ->
        digest =
          :crypto.hash(:sha256, :erlang.term_to_binary({method, Map.delete(params, "_meta")}))

        "upstream:" <> Base.url_encode64(binary_part(digest, 0, 12), padding: false)
    end
  end

  defp legacy_key(key, _method, _params), do: key

  # ---- errors

  # An upstream's JSON-RPC error goes to the client as it is, but for
  # those about the proxy's own exchange with the upstream (its headers,
  # its protocol version). Anything else is the proxy's to log, and the
  # client learns only that the upstream failed.
  defp error(_proxy, {:rpc, %{"code" => code, "message" => message} = error})
       when is_integer(code) and is_binary(message) do
    cond do
      code in [-32_020, -32_022] ->
        {:error, JSONRPC.code(:internal), "The upstream server refused the request."}

      is_map(error["data"]) ->
        {:error, code, message, error["data"]}

      true ->
        {:error, code, message}
    end
  end

  # An upstream may send a JSON-RPC error with an HTTP error status (a
  # modern server's unknown method, say): it is the upstream's answer all
  # the same.
  defp error(proxy, {:http, _status, %{"error" => %{} = error}}), do: error(proxy, {:rpc, error})

  defp error(_proxy, {:credentials, message}),
    do: {:error, JSONRPC.code(:invalid_request), message}

  defp error(_proxy, {:unauthorized, _challenge}),
    do: {:error, JSONRPC.code(:internal), "The upstream server refused the proxy's credentials."}

  defp error(_proxy, {:insufficient_scope, challenge}) do
    {:error, JSONRPC.code(:internal),
     "The upstream server needs scopes the proxy's credentials do not have: " <>
       Enum.join(List.wrap(challenge.scope), " ")}
  end

  defp error(_proxy, {:insufficient_user_authentication, _challenge}) do
    {:error, JSONRPC.code(:internal),
     "The upstream server needs a stronger or more recent sign-in than the proxy's credentials carry."}
  end

  defp error(proxy, reason) do
    Logger.warning("#{inspect(proxy)}: the upstream request failed: #{inspect(reason)}")
    {:error, JSONRPC.code(:internal), "The upstream server is not available."}
  end

  # ---- tasks

  @doc """
  Follows the upstream's task to its end, as the proxy's own task (run by
  `Sake.Tasks.Worker`): the upstream's questions become the task's, its
  status message the task's, and cancelling the task (here or by stopping
  its process) cancels the upstream's. Returns the outcome the worker
  records.
  """
  @spec follow(struct(), map(), Context.t()) ::
          {:ok, map()} | {:failed, map()} | :cancelled
  def follow(spec, task, ctx) do
    guard = guard(spec.proxy, task["taskId"], ctx)
    outcome = poll(spec.proxy, task, ctx, %{}, nil)
    send(guard, :done)
    outcome
  end

  @doc "Cancels the upstream's task, which the proxy will not follow."
  @spec cancel_task(struct(), map(), Context.t()) :: :ok
  def cancel_task(spec, task, ctx), do: cancel_quietly(spec.proxy, task["taskId"], ctx)

  defp poll(proxy, task, ctx, asked, message) do
    message = status_message(ctx, task, message)

    cond do
      Sake.Tasks.cancelled?(ctx) ->
        cancel(proxy, task["taskId"], ctx)
        :cancelled

      task["status"] == "completed" ->
        {:ok, tool_result(map(task["result"]) || %{})}

      task["status"] == "failed" ->
        {:failed, task_error(task["error"])}

      task["status"] == "cancelled" ->
        :cancelled

      task["status"] == "input_required" ->
        asked = answer_task(proxy, task, ctx, asked)
        wait_and_poll(proxy, task, ctx, asked, message)

      true ->
        wait_and_poll(proxy, task, ctx, asked, message)
    end
  end

  defp wait_and_poll(proxy, task, ctx, asked, message) do
    interval = task["pollIntervalMs"]
    Process.sleep(if is_integer(interval), do: interval |> max(50) |> min(10_000), else: 1_000)

    case Upstream.call(proxy, ctx, &Sake.Client.get_task(task_session(&1, ctx), task["taskId"])) do
      {:ok, %{"status" => status} = next} when is_binary(status) ->
        poll(proxy, next, ctx, asked, message)

      {:ok, _other} ->
        {:failed, task_error(nil)}

      {:error, reason} ->
        Logger.warning("#{inspect(proxy)}: lost the upstream's task: #{inspect(reason)}")
        {:failed, task_error(nil)}
    end
  end

  # The upstream's questions, asked through the proxy's task; each is
  # answered upstream once.
  defp answer_task(proxy, task, ctx, asked) do
    requests = task["inputRequests"] |> input_requests() |> Map.drop(Map.keys(asked))
    answers = ask(ctx, requests, nil)

    if answers != %{} do
      _ = Upstream.call(proxy, ctx, &update(task_session(&1, ctx), task["taskId"], answers))
    end

    Map.merge(asked, Map.new(requests, fn {key, _} -> {key, true} end))
  end

  defp update(session, id, answers) do
    with {:ok, session} <- Sake.Client.update_task(session, id, answers), do: {:ok, :ok, session}
  end

  defp status_message(ctx, %{"statusMessage" => message}, previous)
       when is_binary(message) and message != previous do
    Progress.report(ctx, 0, nil, message)
    message
  end

  defp status_message(_ctx, _task, previous), do: previous

  defp task_error(%{"code" => code, "message" => message} = error)
       when is_integer(code) and is_binary(message),
       do: Map.take(error, ["code", "message", "data"])

  defp task_error(_error),
    do: %{"code" => JSONRPC.code(:internal), "message" => "The upstream task failed."}

  defp task_session(session, ctx), do: %{prepare(session, ctx) | tasks: true}

  defp cancel(proxy, id, ctx) do
    _ =
      Upstream.call(proxy, ctx, fn session ->
        with {:ok, session} <- Sake.Client.cancel_task(task_session(session, ctx), id),
             do: {:ok, :ok, session}
      end)

    :ok
  end

  # The task's process is stopped outright when the task is cancelled on
  # this node (or outlives its time-to-live): a process linked to it
  # cancels the upstream's task then.
  defp guard(proxy, id, ctx) do
    worker = self()

    spawn(fn ->
      Process.flag(:trap_exit, true)
      Process.link(worker)

      receive do
        :done -> :ok
        {:EXIT, ^worker, :normal} -> :ok
        {:EXIT, ^worker, _reason} -> cancel_quietly(proxy, id, %{ctx | task: nil})
      end
    end)
  end

  # Cancelling upstream is a courtesy: a proxy that has stopped meanwhile
  # has nothing to cancel with.
  defp cancel_quietly(proxy, id, ctx) do
    cancel(proxy, id, ctx)
  rescue
    _exception -> :ok
  end

  # ---- shared

  defp meta(%{} = meta) do
    case Map.delete(meta, Protocol.meta(:server_info)) do
      empty when empty == %{} -> nil
      meta -> meta
    end
  end

  defp meta(_meta), do: nil

  defp map(%{} = value), do: value
  defp map(_value), do: nil

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: nil

  defp put_some(map, _key, nil), do: map
  defp put_some(map, key, value), do: Map.put(map, key, value)
end
