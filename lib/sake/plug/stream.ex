defmodule Sake.Plug.Stream do
  @moduledoc false
  # One request → one response, as JSON or as an SSE stream, plus the two
  # long-lived streams: subscriptions/listen (modern) and GET (legacy).

  import Plug.Conn

  alias Sake.{Context, JSONRPC, Protocol}
  alias Sake.Plug.{SSE, Streams}

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

    tool_streams =
      method == "tools/call" and
        match?({:ok, %{stream: true}}, Sake.Server.tool(ctx.server, params["name"] || ""))

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
    task = Task.async(fn -> run(parsed, ctx, handler) end)
    loop(conn, opts, id, ctx, task)
  end

  defp loop(conn, opts, id, ctx, task) do
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

      {ref, outcome} when ref == task.ref ->
        Process.demonitor(ref, [:flush])
        finish(conn, id, ctx, after_outcome(outcome, ctx))

      {:DOWN, ref, :process, _pid, reason} when ref == task.ref ->
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
    legacy_loop(conn, opts, MapSet.new())
  end

  defp legacy_loop(conn, opts, subscribed) do
    receive do
      {:sake_subscribe, uri} ->
        legacy_loop(conn, opts, MapSet.put(subscribed, uri))

      {:sake_unsubscribe, uri} ->
        legacy_loop(conn, opts, MapSet.delete(subscribed, uri))

      {:sake_notify, {:list_changed, kind}} ->
        write_or_stop(
          conn,
          opts,
          subscribed,
          JSONRPC.notification("notifications/#{kind}/list_changed")
        )

      {:sake_notify, {:resource_updated, uri}} ->
        if MapSet.member?(subscribed, uri),
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
