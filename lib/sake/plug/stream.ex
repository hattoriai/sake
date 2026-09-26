defmodule Sake.Plug.Stream do
  @moduledoc false
  # One request → one response, as JSON or as an SSE stream, plus the two
  # long-lived streams: subscriptions/listen (modern) and GET (legacy).

  import Plug.Conn
  require Logger

  alias Sake.{Context, JSONRPC, Protocol}
  alias Sake.Plug.{SSE, Streams}

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
        listen(conn, opts, id, params)

      stream?(method, params, ctx) ->
        stream(conn, opts, parsed, ctx, handler)

      true ->
        Sake.Plug.outcome_to_response(conn, id, run(parsed, ctx, handler) |> after_outcome(ctx))
    end
  end

  defp run({:request, _, _, _} = parsed, ctx, handler), do: handler.(ctx.server, parsed, ctx)

  # Legacy subscribe/unsubscribe reach the session's GET stream.
  defp after_outcome({:subscribe, uri} = o, %{
         era: :legacy,
         conn_assigns: %{sake_session_id: sid},
         server: server
       }) do
    Streams.session_subscribe(server, sid, uri)
    o
  end

  defp after_outcome({:unsubscribe, uri} = o, %{
         era: :legacy,
         conn_assigns: %{sake_session_id: sid},
         server: server
       }) do
    Streams.session_unsubscribe(server, sid, uri)
    o
  end

  defp after_outcome(o, _ctx), do: o

  defp stream?(method, params, ctx) do
    token = get_in(params, ["_meta", "progressToken"])

    # A tool that streams on its own (no progress token asked for) only
    # opens the SSE response when the call is actually allowed; otherwise
    # the scope error is a plain JSON-RPC response with the usual status,
    # instead of a 200 stream carrying the error as its only message.
    tool_streams =
      method == "tools/call" and
        case Sake.Server.tool(ctx.server, params["name"] || "") do
          {:ok, %{stream: true} = spec} -> Sake.Server.allowed?(spec, ctx)
          _ -> false
        end

    legacy_elicit =
      ctx.era == :legacy and method in ["tools/call", "resources/read", "prompts/get"] and
        Map.has_key?(ctx.client_capabilities, "elicitation")

    token != nil or tool_streams or legacy_elicit
  end

  defp stream(conn, opts, {:request, id, _method, params} = parsed, ctx, handler) do
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
    task = Task.async(fn -> run_safely(parsed, ctx, handler) end)
    loop(conn, opts, id, ctx, task)
  end

  # The task is linked (a dead connection must kill the handler), so its
  # body must never exit abnormally: a raise or throw here would tear
  # down the SSE connection via the link before the outcome could become
  # a proper JSON-RPC error.
  defp run_safely(parsed, ctx, handler) do
    run(parsed, ctx, handler)
  rescue
    e ->
      Logger.error("stream handler failed: " <> Exception.format(:error, e, __STACKTRACE__))

      {:error,
       %{
         "code" => JSONRPC.code(:internal),
         "message" => "The request failed: " <> Exception.message(e)
       }}
  catch
    kind, reason ->
      Logger.error("stream handler failed: " <> Exception.format(kind, reason, __STACKTRACE__))

      {:error,
       %{
         "code" => JSONRPC.code(:internal),
         "message" => "The request failed: #{inspect({kind, reason})}"
       }}
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
        params =
          %{"progressToken" => token, "progress" => current}
          |> put_some("total", total)
          |> put_some("message", message)

        continue(
          conn,
          opts,
          id,
          ctx,
          task,
          JSONRPC.notification("notifications/progress", params)
        )

      {:sake_log, level, data} ->
        continue(
          conn,
          opts,
          id,
          ctx,
          task,
          JSONRPC.notification("notifications/message", %{
            "level" => to_string(level),
            "data" => data
          })
        )

      {:sake_elicit, _from, request_id, params} ->
        # Legacy elicitation: the server asks on the stream and the handler waits.
        continue(
          conn,
          opts,
          id,
          ctx,
          task,
          JSONRPC.request(request_id, "elicitation/create", params)
        )

      {^task_ref, outcome} ->
        Process.demonitor(task_ref, [:flush])
        finish(conn, id, ctx, after_outcome(outcome, ctx))

      {:DOWN, ^task_ref, :process, _pid, reason} ->
        finish(
          conn,
          id,
          ctx,
          {:error,
           %{
             "code" => JSONRPC.code(:internal),
             "message" => "The request failed: #{inspect(reason)}"
           }}
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
    message =
      case outcome do
        {:reply, result} ->
          JSONRPC.result(id, result)

        {:error, error} ->
          %{"jsonrpc" => "2.0", "id" => id, "error" => error}

        {:forbidden, _scopes} ->
          JSONRPC.error(id, JSONRPC.code(:invalid_request), "Insufficient scope")

        :noreply ->
          JSONRPC.result(id, %{})

        {:subscribe, _} ->
          JSONRPC.result(id, %{})

        {:unsubscribe, _} ->
          JSONRPC.result(id, %{})

        _ ->
          JSONRPC.error(id, JSONRPC.code(:internal), "Unexpected outcome")
      end

    _ = ctx
    {_, conn} = SSE.event(conn, message)
    conn
  end

  # ---- subscriptions/listen

  @filters %{
    "toolsListChanged" => :tools,
    "promptsListChanged" => :prompts,
    "resourcesListChanged" => :resources
  }

  defp listen(conn, opts, id, params) do
    requested = params["notifications"] || %{}

    honoured =
      requested
      |> Enum.filter(fn
        {k, true} -> Map.has_key?(@filters, k)
        {"resourceSubscriptions", uris} -> is_list(uris) and uris != []
        _ -> false
      end)
      |> Map.new()

    Streams.register_listen(opts.server, id, honoured)
    conn = SSE.start(conn)
    meta = %{Protocol.meta(:subscription_id) => id}

    ack =
      JSONRPC.notification("notifications/subscriptions/acknowledged", %{
        "notifications" => honoured,
        "_meta" => meta
      })

    case SSE.event(conn, ack) do
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
        {_, conn} =
          SSE.event(conn, JSONRPC.result(id, %{"resultType" => "complete", "_meta" => meta}))

        conn
    after
      opts.keepalive ->
        case SSE.comment(conn) do
          {:ok, conn} -> listen_loop(conn, opts, id, honoured, meta)
          {:error, _} -> conn
        end
    end
  end

  defp notification_for({:list_changed, kind}, honoured, meta) do
    key = Enum.find_value(@filters, fn {k, v} -> if v == kind, do: k end)

    if honoured[key] == true,
      do: JSONRPC.notification("notifications/#{kind}/list_changed", %{"_meta" => meta})
  end

  defp notification_for({:resource_updated, uri}, honoured, meta) do
    if uri in (honoured["resourceSubscriptions"] || []),
      do:
        JSONRPC.notification("notifications/resources/updated", %{"uri" => uri, "_meta" => meta})
  end

  # ---- legacy GET stream

  @spec legacy(Plug.Conn.t(), map(), map(), String.t()) :: Plug.Conn.t()
  def legacy(conn, opts, _session, session_id) do
    Streams.register_legacy(opts.server, session_id)
    conn = SSE.start(conn)
    legacy_loop(conn, opts, %{})
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

      {:sake_notify, {:list_changed, kind}} ->
        write_or_stop(
          conn,
          opts,
          subscribed,
          JSONRPC.notification("notifications/#{kind}/list_changed")
        )

      {:sake_notify, {:resource_updated, uri}} ->
        if Map.has_key?(subscribed, uri),
          do:
            write_or_stop(
              conn,
              opts,
              subscribed,
              JSONRPC.notification("notifications/resources/updated", %{"uri" => uri})
            ),
          else: legacy_loop(conn, opts, subscribed)
    after
      opts.keepalive ->
        case SSE.comment(conn) do
          {:ok, conn} -> legacy_loop(conn, opts, subscribed)
          {:error, _} -> conn
        end
    end
  end

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
