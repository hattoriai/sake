defmodule Sake.Plug.Stream do
  @moduledoc false
  # One request → one response, as JSON or as an SSE stream, plus the two
  # long-lived streams: subscriptions/listen (modern, including the tasks
  # extension's `notifications/tasks`) and GET (legacy).

  import Plug.Conn
  require Logger

  alias Sake.{Context, JSONRPC, Protocol, Trace}
  alias Sake.Plug.{Resumable, SSE, Streams}
  alias Sake.Server.Middleware

  # `loop/5` demonitors `Task.async/1`'s own monitor ref by hand (there is
  # no public `Task` API to do this outside a `receive`, which is exactly
  # what it is inside); `Task.ref/0` is `@opaque`, and Dialyzer flags using
  # the plain `reference()` it wraps for anything besides matching it back
  # in a `receive`. The value is a `reference()` at runtime regardless —
  # this silences a known-safe crossing of that opacity, not a real bug.
  @dialyzer {:no_opaque, loop: 5}

  @spec respond(Plug.Conn.t(), map(), Sake.JSONRPC.parsed(), Context.t(), function()) ::
          Plug.Conn.t()
  def respond(conn, opts, {:request, id, method, params} = parsed, ctx, handler) do
    cond do
      method == "subscriptions/listen" and ctx.era == :modern ->
        listen(conn, opts, id, params, ctx)

      stream?(method, params, ctx) ->
        stream(conn, opts, parsed, ctx, handler)

      true ->
        outcome = parsed |> run_safely(ctx, handler) |> after_outcome(ctx) |> Trace.outcome()
        Sake.Plug.outcome_to_response(conn, id, outcome)
    end
  end

  defp run({:request, _, _, _} = parsed, ctx, handler), do: handler.(ctx.server, parsed, ctx)

  # Legacy subscribe/unsubscribe reach the session's GET stream.
  defp after_outcome({:subscribe, uri} = o, %{
         era: :legacy,
         conn_assigns: %{sake_session_nonce: nonce},
         server: server
       }) do
    Streams.session_subscribe(server, nonce, uri)
    o
  end

  defp after_outcome({:unsubscribe, uri} = o, %{
         era: :legacy,
         conn_assigns: %{sake_session_nonce: nonce},
         server: server
       }) do
    Streams.session_unsubscribe(server, nonce, uri)
    o
  end

  defp after_outcome(o, _ctx), do: o

  @asks ["elicitation", "sampling", "roots"]

  # A call refused for its scopes, or for how the person signed in, is
  # never streamed, whatever asked for a stream: the refusal is a plain
  # JSON-RPC response with the usual status (a 403 or a 401 with its
  # challenge, for a client to step up), instead of a 200 stream carrying
  # the error as its only message.
  defp stream?(method, params, ctx),
    do: not refused?(method, params, ctx) and streamed?(method, params, ctx)

  defp streamed?(method, params, ctx) do
    token = get_in(params, ["_meta", "progressToken"])

    tool_streams =
      method == "tools/call" and
        match?({:ok, %{stream: true}}, Sake.Server.tool(ctx.server, params["name"] || "", ctx))

    # A legacy client that can be asked something (elicitation, sampling,
    # roots) gets the stream the question would travel on.
    legacy_asks =
      ctx.era == :legacy and method in ["tools/call", "resources/read", "prompts/get"] and
        Enum.any?(@asks, &Map.has_key?(ctx.client_capabilities, &1))

    token != nil or tool_streams or legacy_asks
  end

  defp refused?(method, params, ctx) do
    case component(method, params, ctx) do
      {:ok, spec} -> Sake.Server.permit(spec, ctx) != :ok
      _ -> false
    end
  end

  defp component("tools/call", params, ctx),
    do: Sake.Server.tool(ctx.server, params["name"] || "", ctx)

  defp component("prompts/get", params, ctx),
    do: Sake.Server.prompt(ctx.server, params["name"] || "", ctx)

  defp component("resources/read", %{"uri" => uri}, ctx) when is_binary(uri) do
    with {:ok, spec, _params} <- Sake.Server.resource(ctx.server, uri, ctx), do: {:ok, spec}
  end

  defp component(_method, _params, _ctx), do: :error

  defp stream(conn, opts, parsed, ctx, handler) do
    if resumable?(opts, ctx),
      do: resumable(conn, opts, parsed, ctx, handler),
      else: plain(conn, opts, parsed, ctx, handler)
  end

  # A legacy session's stream is resumable (see "Resumable streams" in
  # `Sake.Plug`): the modern revision has none, and a stream without a
  # session has nothing to resume it under.
  defp resumable?(opts, %Context{era: :legacy, conn_assigns: %{sake_session_nonce: nonce}})
       when is_binary(nonce),
       do: Map.get(opts, :resumable, false)

  defp resumable?(_opts, _ctx), do: false

  # The call runs in its stream's process (`Sake.Plug.Resumable`), not in
  # this connection's: a dropped connection leaves it running, its events
  # kept for the client's GET with `Last-Event-ID`.
  defp resumable(conn, opts, {:request, id, _method, params} = parsed, ctx, handler) do
    nonce = ctx.conn_assigns.sake_session_nonce
    token = get_in(params, ["_meta", "progressToken"])

    run =
      Trace.bind(fn ->
        owner = Resumable.owner()
        ctx = %{ctx | progress: owner_progress(owner, token), transport: owner}
        run_safely(parsed, ctx, handler)
      end)

    {:ok, _pid, sid} = Resumable.start_call(opts, nonce, run, id, {:pid, self()})
    conn = SSE.start(conn)

    case SSE.prime(conn, sid <> ".0", opts.sse_retry, ctx.protocol_version) do
      {:ok, conn} -> serve(conn, opts, sid, {:pid, self()})
      {:error, _} -> leave(conn, sid, {:pid, self()})
    end
  end

  defp owner_progress(_owner, nil), do: fn _, _ -> :ok end

  defp owner_progress(owner, token) do
    fn current, {total, message} ->
      send(owner, {:sake_progress, token, current, total, message})
    end
  end

  # Writes the stream's events, each with its ID, until the stream closes
  # the connection (its call's response was sent, or the handler asked for
  # it) or the client goes. The stream then stops sending here.
  defp serve(conn, opts, sid, subscriber) do
    receive do
      {:sake_sse, ^sid, {:event, n, message}} ->
        case SSE.event(conn, message, sid <> "." <> Integer.to_string(n)) do
          {:ok, conn} -> serve(conn, opts, sid, subscriber)
          {:error, _} -> leave(conn, sid, subscriber)
        end

      {:sake_sse, ^sid, :close} ->
        leave(conn, sid, subscriber)
    after
      opts.keepalive ->
        case SSE.comment(conn) do
          {:ok, conn} -> serve(conn, opts, sid, subscriber)
          {:error, _} -> leave(conn, sid, subscriber)
        end
    end
  end

  defp leave(conn, sid, {:pid, _} = subscriber) do
    Resumable.detach(sid, subscriber)
    conn
  end

  defp leave(conn, sid, {:topic, topic}) do
    _ = Streams.detach_remote(sid, topic)
    if pubsub = Streams.pubsub(), do: Streams.unsubscribe(pubsub, topic)
    conn
  end

  defp plain(conn, opts, {:request, id, _method, params} = parsed, ctx, handler) do
    conn = SSE.start(conn)
    me = self()
    token = get_in(params, ["_meta", "progressToken"])

    progress =
      if token,
        do: fn current, {total, message} ->
          send(me, {:sake_progress, token, current, total, message})
        end,
        else: fn _, _ -> :ok end

    ctx = %{ctx | progress: progress, transport: me}
    task = Task.async(Trace.bind(fn -> run_safely(parsed, ctx, handler) end))
    loop(conn, opts, id, ctx, task)
  end

  # A failing handler becomes a JSON-RPC error on both paths. On the
  # stream path the task is linked (a dead connection must kill the
  # handler), so its body must never exit abnormally: a raise or throw
  # there would tear down the SSE connection via the link before the
  # outcome could become a proper JSON-RPC error.
  @doc false
  def run_safely(parsed, ctx, handler) do
    run(parsed, ctx, handler)
  catch
    kind, reason -> {:error, failure(kind, reason, __STACKTRACE__)}
  end

  @doc false
  # The error a client gets for a failure inside the server. It says
  # nothing of the failure: an exception's message may carry anything (a
  # query, a credential, a path). Its `errorId` tags the log line, and the
  # exception recorded on the request's span, that do.
  @spec failure(:error | :exit | :throw, term(), Exception.stacktrace()) :: map()
  def failure(kind, reason, stacktrace) do
    id = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

    Logger.error("request failed (error #{id}): " <> Exception.format(kind, reason, stacktrace))

    Trace.exception(kind, reason, stacktrace, id)

    %{
      "code" => JSONRPC.code(:internal),
      "message" => "The request failed.",
      "data" => %{"errorId" => id}
    }
  end

  @spec loop(Plug.Conn.t(), map(), term(), Context.t(), Task.t()) :: Plug.Conn.t()
  defp loop(conn, opts, id, ctx, task) do
    # Matched by pinning, not `when ref == task.ref`: `Task.ref/0` is
    # `@opaque`, and comparing an opaque value with `==` in a guard (rather
    # than unifying it in a pattern) is exactly what Dialyzer's opaqueness
    # check exists to catch. Extracting the field itself is unavoidable —
    # `Task` has no public API to demonitor or pattern-match its own
    # monitor ref outside a `receive` — hence `@dialyzer` below.
    %Task{ref: task_ref} = task

    receive do
      {:sake_progress, token, current, total, message} ->
        continue(conn, opts, id, ctx, task, progress(token, current, total, message))

      {:sake_log, level, data} ->
        continue(conn, opts, id, ctx, task, log(level, data))

      {:sake_request, _from, request_id, method, params} ->
        # A legacy server request (elicitation, sampling, roots): the server
        # asks on the stream and the handler waits.
        continue(conn, opts, id, ctx, task, JSONRPC.request(request_id, method, params))

      # `Sake.Progress.close_stream/1` on a stream that is not resumable:
      # closing it would lose the response, so it stays open.
      :sake_close_stream ->
        loop(conn, opts, id, ctx, task)

      {^task_ref, outcome} ->
        Process.demonitor(task_ref, [:flush])
        finish(conn, id, ctx, after_outcome(outcome, ctx))

      {:DOWN, ^task_ref, :process, _pid, reason} ->
        finish(
          conn,
          id,
          ctx,
          {:error, failure(:exit, reason, [])}
        )
    after
      opts.keepalive ->
        case SSE.comment(conn) do
          {:ok, conn} -> loop(conn, opts, id, ctx, task)
          {:error, _} -> cancel(conn, task)
        end
    end
  end

  defp continue(conn, opts, id, ctx, task, message) do
    case SSE.event(conn, message) do
      {:ok, conn} -> loop(conn, opts, id, ctx, task)
      {:error, _} -> cancel(conn, task)
    end
  end

  defp cancel(conn, task) do
    Task.shutdown(task, :brutal_kill)
    Process.put(:sake_cancelled, true)
    conn
  end

  defp finish(conn, id, ctx, outcome) do
    _ = ctx
    SSE.last_event(conn, response(id, Trace.outcome(outcome)))
  end

  # The messages a request's stream carries, shared with `Sake.Stdio`.

  @doc false
  def response(id, outcome) do
    case outcome do
      {:reply, result} ->
        JSONRPC.result(id, result)

      {:error, error} ->
        %{"jsonrpc" => "2.0", "id" => id, "error" => error}

      {:forbidden, scopes} ->
        %{"jsonrpc" => "2.0", "id" => id, "error" => forbidden(scopes)}

      {:insufficient_user_authentication, _refusal} ->
        %{"jsonrpc" => "2.0", "id" => id, "error" => insufficient_user_authentication()}

      :noreply ->
        JSONRPC.result(id, %{})

      {:subscribe, _} ->
        JSONRPC.result(id, %{})

      {:unsubscribe, _} ->
        JSONRPC.result(id, %{})

      _ ->
        JSONRPC.error(id, JSONRPC.code(:internal), "Unexpected outcome")
    end
  end

  @doc false
  # The error of a refusal: for missing scopes, or, with none to name, a
  # middleware's refusal that no scope would lift.
  def forbidden([]), do: %{"code" => JSONRPC.code(:invalid_request), "message" => "Forbidden"}

  def forbidden(_scopes),
    do: %{"code" => JSONRPC.code(:invalid_request), "message" => "Insufficient scope"}

  @doc false
  # The error of a refusal for how the person signed in (RFC 9470).
  def insufficient_user_authentication,
    do: %{
      "code" => JSONRPC.code(:invalid_request),
      "message" => "Insufficient user authentication"
    }

  @doc false
  def progress(token, current, total, message) do
    params =
      %{"progressToken" => token, "progress" => current}
      |> put_some("total", total)
      |> put_some("message", message)

    JSONRPC.notification("notifications/progress", params)
  end

  @doc false
  def log(level, data),
    do:
      JSONRPC.notification("notifications/message", %{
        "level" => to_string(level),
        "data" => data
      })

  # ---- subscriptions/listen

  @filters %{
    "toolsListChanged" => :tools,
    "promptsListChanged" => :prompts,
    "resourcesListChanged" => :resources
  }

  # Task notifications need the tasks extension; a client asking for them
  # without it gets -32021 instead of a stream.
  defp listen(conn, opts, id, params, ctx) do
    ctx = %{ctx | request_id: id, method: "subscriptions/listen"}

    case refused(params, ctx) do
      nil -> open_listen(conn, opts, id, params, ctx)
      outcome -> Sake.Plug.outcome_to_response(conn, id, Trace.outcome(outcome))
    end
  end

  defp open_listen(conn, opts, id, params, ctx) do
    honoured = honoured(params, ctx)
    Streams.register_listen(opts.server, id, honoured)
    conn = SSE.start(conn)
    meta = %{Protocol.meta(:subscription_id) => id}

    case SSE.event(conn, acknowledged(honoured, meta)) do
      {:ok, conn} -> listen_loop(conn, opts, id, honoured, meta)
      {:error, _} -> conn
    end
  end

  defp listen_loop(conn, opts, id, honoured, meta) do
    receive do
      {:sake_notify, event} ->
        case notification_for(event, honoured, meta) do
          nil ->
            listen_loop(conn, opts, id, honoured, meta)

          message ->
            case SSE.event(conn, message) do
              {:ok, conn} -> listen_loop(conn, opts, id, honoured, meta)
              {:error, _} -> conn
            end
        end

      :sake_shutdown ->
        conn =
          SSE.last_event(
            conn,
            JSONRPC.result(id, %{"resultType" => "complete", "_meta" => meta})
          )

        Streams.unregister_listen(opts.server)
        conn
    after
      opts.keepalive ->
        case SSE.comment(conn) do
          {:ok, conn} -> listen_loop(conn, opts, id, honoured, meta)
          {:error, _} -> conn
        end
    end
  end

  # The part of a `subscriptions/listen` filter Sake honours, its
  # acknowledgement, and the notification (if any) an event becomes on the
  # stream; shared with `Sake.Stdio`.

  @doc false
  # The outcome a listen request gets instead of a stream, if any: the
  # server's `:before_request` middleware may refuse it, and task
  # notifications need the tasks extension.
  def refused(params, ctx) do
    case Middleware.before_request(params, ctx) do
      {:halt, reason} -> reason |> Middleware.refusal(params, ctx) |> refusal_outcome()
      {:ok, ctx} -> missing_tasks(params["notifications"], ctx)
    end
  end

  defp missing_tasks(requested, ctx) do
    if is_map(requested) and Map.has_key?(requested, "taskIds") and
         not Sake.Server.Tasks.declared?(ctx) do
      {:error, code, message, data} = Sake.Server.Tasks.missing_capability()
      {:error, %{"code" => code, "message" => message, "data" => data}}
    end
  end

  defp refusal_outcome({:forbidden, scopes}), do: {:forbidden, scopes}

  defp refusal_outcome({:insufficient_user_authentication, refusal}),
    do: {:insufficient_user_authentication, refusal}

  defp refusal_outcome({:error, code, message}),
    do: {:error, %{"code" => code, "message" => message}}

  defp refusal_outcome({:error, code, message, data}),
    do: {:error, %{"code" => code, "message" => message, "data" => data}}

  @doc false
  def honoured(params, ctx) do
    requested = params["notifications"] || %{}

    extensions = Sake.Server.Extensions.notifying(ctx.server)

    requested
    |> Enum.filter(fn
      {k, true} -> Map.has_key?(@filters, k) or k in extensions
      {"resourceSubscriptions", uris} -> is_list(uris) and uris != []
      _ -> false
    end)
    |> Map.new()
    |> subscribable(ctx)
    |> put_task_ids(Sake.Server.Tasks.visible(is_map(requested) && requested["taskIds"], ctx))
  end

  # A URI is honoured on the terms of a legacy `resources/subscribe`: a
  # resource that declares `subscribe: true`, that the server's
  # `:after_list` middleware does not hide, and whose scopes the token
  # carries. Any other URI, an unknown one too, is left out of what the
  # stream honours, so the caller cannot tell them apart.
  defp subscribable(%{"resourceSubscriptions" => uris} = honoured, ctx) do
    case Enum.filter(uris, &subscribable?(&1, ctx)) do
      [] -> Map.delete(honoured, "resourceSubscriptions")
      uris -> Map.put(honoured, "resourceSubscriptions", uris)
    end
  end

  defp subscribable(honoured, _ctx), do: honoured

  # A proxied resource it honours is followed upstream (see `Sake.Proxy`).
  defp subscribable?(uri, ctx) do
    case is_binary(uri) and Sake.Server.resource(ctx.server, uri, ctx) do
      {:ok, %{subscribe: true} = spec, _params} ->
        Middleware.listed(:resources, spec, ctx) == :ok and Sake.Server.allowed?(spec, ctx) and
          followed(spec, uri)

      _ ->
        false
    end
  end

  defp followed(%{proxy: nil}, _uri), do: true
  defp followed(spec, uri), do: Sake.Proxy.follow(spec, uri) == :ok

  # The caller's own tasks only: anything else was left out of `taskIds`.
  defp put_task_ids(honoured, []), do: honoured
  defp put_task_ids(honoured, ids), do: Map.put(honoured, "taskIds", ids)

  @doc false
  def acknowledged(honoured, meta),
    do:
      JSONRPC.notification("notifications/subscriptions/acknowledged", %{
        "notifications" => honoured,
        "_meta" => meta
      })

  @doc false
  def notification_for({:list_changed, kind}, honoured, meta) do
    key = Enum.find_value(@filters, fn {k, v} -> if v == kind, do: k end)

    if honoured[key] == true,
      do: JSONRPC.notification("notifications/#{kind}/list_changed", %{"_meta" => meta})
  end

  def notification_for({:task, task}, honoured, meta) do
    if task["taskId"] in (honoured["taskIds"] || []),
      do: JSONRPC.notification("notifications/tasks", Map.put(task, "_meta", meta))
  end

  # An extension's notification, on a stream that asked for the
  # extension's identifier.
  def notification_for({:extension, id, method, params}, honoured, meta) do
    if honoured[id] == true,
      do:
        JSONRPC.notification(
          method,
          Map.put(params, "_meta", Map.merge(params["_meta"] || %{}, meta))
        )
  end

  def notification_for({:resource_updated, uri}, honoured, meta) do
    if uri in (honoured["resourceSubscriptions"] || []),
      do:
        JSONRPC.notification("notifications/resources/updated", %{"uri" => uri, "_meta" => meta})
  end

  # ---- legacy GET stream

  @spec legacy(Plug.Conn.t(), map(), Sake.Server.Session.session()) :: Plug.Conn.t()
  def legacy(conn, opts, session) do
    cond do
      not Map.get(opts, :resumable, false) ->
        plain_legacy(conn, opts, session)

      last = List.first(get_req_header(conn, "last-event-id")) ->
        resume(conn, opts, session, last)

      true ->
        resumable_legacy(conn, opts, session)
    end
  end

  # The session's notifications through a resumable stream: kept while the
  # client is away, for its GET with `Last-Event-ID`.
  defp resumable_legacy(conn, opts, session) do
    {:ok, _pid, sid} = Resumable.start_session(opts, session.nonce, {:pid, self()})
    conn = SSE.start(conn)

    case SSE.prime(conn, sid <> ".0", opts.sse_retry, session.revision) do
      {:ok, conn} -> serve(conn, opts, sid, {:pid, self()})
      {:error, _} -> leave(conn, sid, {:pid, self()})
    end
  end

  # A GET with `Last-Event-ID`: the stream it names, from the event after
  # it, here or (with a pubsub) on the node that has it. One that is not
  # the session's, or is gone, is refused: the client starts over.
  defp resume(conn, opts, session, last) do
    case Resumable.parse_id(last) do
      {:ok, sid, n} ->
        case Resumable.attach(sid, session.nonce, n, {:pid, self()}) do
          :ok -> resumed(conn, opts, sid, {:pid, self()})
          :evicted -> unknown_event(conn)
          :error -> resume_remote(conn, opts, session, sid, n)
        end

      :error ->
        unknown_event(conn)
    end
  end

  defp resume_remote(conn, opts, session, sid, n) do
    case Streams.pubsub() do
      nil ->
        unknown_event(conn)

      pubsub ->
        topic = "sake:sse:" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
        :ok = Streams.subscribe(pubsub, topic)
        _ = Streams.resume_remote(sid, session.nonce, n, topic)

        receive do
          {:sake_sse_found, ^sid} -> resumed(conn, opts, sid, {:topic, topic})
        after
          2_000 ->
            Streams.unsubscribe(pubsub, topic)
            unknown_event(conn)
        end
    end
  end

  # The replayed events are already waiting in the mailbox: the stream
  # sent them as it attached.
  defp resumed(conn, opts, sid, subscriber) do
    conn = SSE.start(conn)

    case Plug.Conn.chunk(conn, ["retry: ", Integer.to_string(opts.sse_retry), "\n\n"]) do
      {:ok, conn} -> serve(conn, opts, sid, subscriber)
      {:error, _} -> leave(conn, sid, subscriber)
    end
  end

  defp unknown_event(conn) do
    body =
      JSONRPC.error(nil, JSONRPC.code(:invalid_request), "Unknown or expired Last-Event-ID")

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(400, Sake.JSON.encode!(body))
  end

  defp plain_legacy(conn, opts, session) do
    Streams.register_legacy(opts.server, session.nonce)

    # A comment at once tells the client the stream is open: the session's
    # subscriptions live on it, so a client subscribes once it is.
    case conn |> SSE.start() |> SSE.comment() do
      {:ok, conn} -> legacy_loop(conn, opts, %{})
      {:error, _} -> conn
    end
  end

  # `subscribed` is a set of URIs kept as a plain map (URI => true): a
  # `MapSet` here defeats Dialyzer's opaqueness checking under the current
  # toolchain (its `:sets` internals changed shape and the local recursive
  # function's inferred success typing stops matching `MapSet.t()` at
  # every call site) even though the code itself was correct.
  @spec legacy_loop(Plug.Conn.t(), map(), %{String.t() => true}) :: Plug.Conn.t()
  defp legacy_loop(conn, opts, subscribed) do
    receive do
      {:sake_subscribe, uri} ->
        legacy_loop(conn, opts, Map.put(subscribed, uri, true))

      {:sake_unsubscribe, uri} ->
        legacy_loop(conn, opts, Map.delete(subscribed, uri))

      {:sake_notify, event} ->
        case legacy_notification(event, subscribed) do
          nil -> legacy_loop(conn, opts, subscribed)
          message -> write_or_stop(conn, opts, subscribed, message)
        end
    after
      opts.keepalive ->
        case SSE.comment(conn) do
          {:ok, conn} -> legacy_loop(conn, opts, subscribed)
          {:error, _} -> conn
        end
    end
  end

  @doc false
  # What a legacy session's GET stream carries for a broadcast, if
  # anything: a list change, an update of a resource it subscribed to, an
  # extension's notification (a legacy session has no filter to ask for
  # one with, so it gets them all). Task notifications are for modern
  # listen streams only.
  @spec legacy_notification(term(), %{String.t() => true}) :: map() | nil
  def legacy_notification({:list_changed, kind}, _subscribed),
    do: JSONRPC.notification("notifications/#{kind}/list_changed")

  def legacy_notification({:resource_updated, uri}, subscribed) do
    if Map.has_key?(subscribed, uri),
      do: JSONRPC.notification("notifications/resources/updated", %{"uri" => uri})
  end

  def legacy_notification({:extension, _id, method, params}, _subscribed),
    do: JSONRPC.notification(method, params)

  def legacy_notification(_event, _subscribed), do: nil

  @spec write_or_stop(Plug.Conn.t(), map(), %{String.t() => true}, map()) :: Plug.Conn.t()
  defp write_or_stop(conn, opts, subscribed, message) do
    case SSE.event(conn, message) do
      {:ok, conn} -> legacy_loop(conn, opts, subscribed)
      {:error, _} -> conn
    end
  end

  # ---- a legacy client's response to a server request

  @spec client_response(Plug.Conn.t(), map(), Context.t(), term(), {:ok, map()} | {:error, map()}) ::
          Plug.Conn.t()
  def client_response(conn, _opts, _ctx, id, response) do
    _ = Streams.deliver_response(id, response)
    send_resp(conn, 202, "")
  end

  defp put_some(map, _k, nil), do: map
  defp put_some(map, k, v), do: Map.put(map, k, v)
end
