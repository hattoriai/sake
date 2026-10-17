defmodule Sake.Test.Endpoint do
  @moduledoc false
  # The in-memory transport of `Sake.Test`: what `Sake.Plug` does with a
  # request, minus HTTP. `Sake.Client` hands it each message it would have
  # sent (`Sake.Client.Transport.post/3`), and it answers with the message
  # the server would have sent back, through the same dispatchers, with a
  # real `Sake.Context`.
  #
  # Every message crosses as JSON, both ways, so a component sees exactly
  # what it would see on the wire, and the test sees exactly what a client
  # would. The request runs in a task while the calling process relays its
  # progress and log messages to `on_notification` and answers a legacy
  # server request (elicitation, sampling, roots) with the session's
  # `on_input`, `sampling` and `roots`, as `Sake.Client.Stdio` does.
  #
  # A legacy session lives where it does on HTTP: in the signed session
  # ID (`Sake.Server.Session`), which the client keeps.

  alias Sake.Auth.Challenge
  alias Sake.Client.{Session, Transport}
  alias Sake.{Context, JSONRPC, Protocol, Trace}
  alias Sake.Plug.{Stream, Streams}
  alias Sake.Server.{Dispatch, Legacy}
  alias Sake.Tasks.Record

  # `loop/2` demonitors the task's monitor ref by hand, exactly as
  # `Sake.Plug.Stream` does; see the note there.
  @dialyzer {:no_opaque, loop: 2}

  @type t :: %__MODULE__{}
  defstruct [:server, :scope, :token, :secret, reraise: true]

  @spec new(module(), keyword()) :: t()
  def new(server, opts) do
    %__MODULE__{
      server: server,
      scope: opts[:scope],
      token: opts[:token],
      secret: opts[:secret],
      reraise: Keyword.get(opts, :reraise, true)
    }
  end

  @spec post(Session.t(), map(), keyword()) ::
          {:ok, map() | :accepted, Session.t()} | {:error, term()}
  def post(%Session{local: endpoint} = session, message, _opts) do
    parsed = message |> wire() |> JSONRPC.parse()

    case Sake.Plug.shape(parsed) do
      :ok -> message(endpoint, session, parsed)
      {:error, :params, id, text} -> reply(session, JSONRPC.error(id, invalid_params(), text))
    end
  end

  defp message(endpoint, session, {:request, _id, "initialize", _params} = parsed),
    do: initialize(endpoint, session, parsed)

  defp message(endpoint, %Session{era: :legacy} = session, {:request, _, _, _} = parsed),
    do: legacy(endpoint, session, parsed)

  defp message(endpoint, session, {:request, _, _, _} = parsed),
    do: modern(endpoint, session, parsed)

  # A legacy client's answer to a request a handler sent it.
  defp message(_endpoint, session, {:response, id, result}) do
    _ = Streams.deliver_response(id, {:ok, result})
    {:ok, :accepted, session}
  end

  defp message(_endpoint, session, {:error_response, id, error}) do
    _ = Streams.deliver_response(id, {:error, error})
    {:ok, :accepted, session}
  end

  defp message(_endpoint, session, _notification_or_batch), do: {:ok, :accepted, session}

  defp reply(session, message), do: {:ok, wire(message), session}

  defp invalid_params, do: JSONRPC.code(:invalid_params)

  # ---- modern

  # The `_meta` checks of `Sake.Plug`, without the header layer.
  defp modern(endpoint, session, {:request, id, _method, params} = parsed) do
    meta = params["_meta"] || %{}
    version = meta[Protocol.meta(:protocol_version)]

    cond do
      Protocol.era(version) != :modern ->
        reply(
          session,
          JSONRPC.error(id, JSONRPC.code(:unsupported_version), "Unsupported protocol version", %{
            "supported" => Protocol.supported(),
            "requested" => version
          })
        )

      not is_map(meta[Protocol.meta(:client_capabilities)]) ->
        reply(
          session,
          JSONRPC.error(
            id,
            invalid_params(),
            "Missing #{Protocol.meta(:client_capabilities)} in _meta"
          )
        )

      not (is_nil(meta[Protocol.meta(:log_level)]) or
               Sake.Progress.level?(meta[Protocol.meta(:log_level)])) ->
        reply(session, JSONRPC.error(id, invalid_params(), "Unknown log level"))

      true ->
        ctx =
          context(endpoint,
            era: :modern,
            protocol_version: version,
            client_info: map(meta[Protocol.meta(:client_info)]),
            client_capabilities: meta[Protocol.meta(:client_capabilities)],
            log_level: meta[Protocol.meta(:log_level)],
            trace: Map.take(meta, ["traceparent", "tracestate", "baggage"])
          )

        respond(endpoint, session, parsed, ctx, &Dispatch.handle/3, nil)
    end
  end

  # ---- legacy

  defp initialize(endpoint, session, {:request, id, "initialize", _params} = parsed) do
    ctx = context(endpoint, era: :legacy)

    outcome =
      Trace.server(parsed, ctx, {:local, nil}, fn ->
        endpoint.server |> Legacy.handle(parsed, ctx) |> Trace.outcome()
      end)

    case outcome do
      {:initialize, revision, capabilities, result} ->
        session_id = Sake.Server.Session.mint(ctx.secret, revision, capabilities)
        reply(%{session | session_id: session_id}, JSONRPC.result(id, result))

      {:error, error} ->
        reply(session, %{"jsonrpc" => "2.0", "id" => id, "error" => error})
    end
  end

  defp legacy(endpoint, session, {:request, id, _method, _params} = parsed) do
    secret = secret(endpoint)

    case Sake.Server.Session.verify(secret, session.session_id) do
      {:ok, legacy} ->
        ctx =
          context(endpoint,
            era: :legacy,
            protocol_version: legacy.revision,
            client_capabilities: legacy.capabilities,
            log_level: legacy.log_level
          )

        session = renew(session, secret, legacy, parsed)
        respond(endpoint, session, parsed, ctx, &Legacy.handle/3, legacy.nonce)

      :error ->
        reply(session, JSONRPC.error(id, JSONRPC.code(:invalid_request), "Unknown session"))
    end
  end

  # `logging/setLevel` re-mints the session ID with the new level, as
  # `Sake.Plug` does; the client keeps the ID of every response.
  defp renew(session, secret, legacy, {:request, _, "logging/setLevel", %{"level" => level}}) do
    if Sake.Progress.level?(level),
      do: %{session | session_id: Sake.Server.Session.renew(secret, legacy, level)},
      else: session
  end

  defp renew(session, _secret, _legacy, _parsed), do: session

  # ---- the context

  defp context(endpoint, opts) do
    token = endpoint.token

    [
      scope: scope(endpoint.scope),
      token: token,
      scopes: if(token, do: token.scopes, else: []),
      secret: secret(endpoint),
      server: endpoint.server,
      reraise: endpoint.reraise
    ]
    |> Keyword.merge(opts)
    |> Context.new()
  end

  # The principal is computed for every request, as `Sake.Plug` computes
  # it from every conn.
  defp scope(fun) when is_function(fun, 0), do: fun.()
  defp scope(value), do: value

  # Cursors and request states are signed with the host's secret when it
  # has one. Otherwise any fixed secret serves: they only ever travel
  # between the test and its server, and every client shares it, so a
  # request state one client obtained is refused to another for its
  # principal, as in production, and not for its signature.
  defp secret(%__MODULE__{secret: nil}),
    do: Sake.Secret.configured() || String.duplicate("sake-test", 4)

  defp secret(%__MODULE__{secret: secret}), do: Sake.Secret.resolve(secret)

  defp map(value) when is_map(value), do: value
  defp map(_value), do: %{}

  # ---- one request

  # `nonce` is the legacy session's identity, for its span.
  defp respond(endpoint, session, {:request, id, method, params} = parsed, ctx, handler, nonce) do
    meta = %{
      method: method,
      component: params["name"] || params["uri"],
      era: ctx.era,
      protocol_version: ctx.protocol_version,
      client_name: ctx.client_info["name"]
    }

    outcome =
      Trace.server(parsed, ctx, {:local, nonce}, fn ->
        :telemetry.span([:sake, :server, :request], meta, fn ->
          outcome = run(endpoint, session, parsed, ctx, handler)
          {outcome, Map.put(meta, :cancelled, false)}
        end)
      end)

    case outcome do
      {:raised, kind, reason, stacktrace} ->
        :erlang.raise(kind, reason, stacktrace)

      {:forbidden, []} ->
        {:error, {:http, 403, Stream.response(id, {:forbidden, []})}}

      {:forbidden, scopes} ->
        {:error, {:insufficient_scope, challenge(scopes)}}

      {:insufficient_user_authentication, r} ->
        {:error, {:insufficient_user_authentication, step_up(r)}}

      outcome ->
        reply(session, Stream.response(id, outcome))
    end
  end

  # A refusal for how the person signed in is the 401 an endpoint with
  # authorization answers it with (RFC 9470).
  defp step_up(refusal) do
    %Challenge{
      scheme: "Bearer",
      status: 401,
      error: "insufficient_user_authentication",
      acr_values: refusal.acr_values,
      max_age: refusal.max_age,
      scope: refusal.scopes
    }
  end

  # A scope refusal is what `Sake.Client` sees from an endpoint with
  # authorization: a 403 with an `insufficient_scope` challenge.
  defp challenge(scopes),
    do: %Challenge{scheme: "Bearer", error: "insufficient_scope", scope: scopes}

  # The handler runs in a task while this process relays its messages to
  # the client, as the SSE loop of `Sake.Plug.Stream` does.
  defp run(endpoint, session, {:request, _id, _method, params} = parsed, ctx, handler) do
    me = self()
    token = get_in(params, ["_meta", "progressToken"])

    progress =
      if token,
        do: fn current, {total, message} ->
          send(me, {:sake_progress, token, current, total, message})
        end,
        else: fn _, _ -> :ok end

    ctx = %{ctx | progress: progress, transport: me}
    task = Task.async(Trace.bind(fn -> execute(parsed, ctx, handler, endpoint.reraise) end))

    case loop(session, task) do
      {:raised, _kind, _reason, _stacktrace} = raised -> raised
      outcome -> Trace.outcome(outcome)
    end
  end

  # With `reraise`, anything the handler raises goes back to the test as
  # it was raised; without it, it becomes the JSON-RPC error a client
  # would get.
  defp execute(parsed, ctx, handler, false), do: Stream.run_safely(parsed, ctx, handler)

  defp execute(parsed, ctx, handler, true) do
    handler.(ctx.server, parsed, ctx)
  catch
    kind, reason -> {:raised, kind, reason, __STACKTRACE__}
  end

  @spec loop(Session.t(), Task.t()) :: term()
  defp loop(session, task) do
    %Task{ref: task_ref} = task

    receive do
      {:sake_progress, token, current, total, message} ->
        notify(session, Stream.progress(token, current, total, message))
        loop(session, task)

      {:sake_log, level, data} ->
        notify(session, Stream.log(level, data))
        loop(session, task)

      {:sake_request, _from, request_id, method, params} ->
        # A legacy server request: the client answers it as it would on
        # the call's stream, and the answer goes back the way a POSTed one
        # does.
        %{"params" => params} = wire(%{"params" => params})

        {:ok, :accepted, _session} =
          post(session, answer(session, task, request_id, method, params), [])

        loop(session, task)

      {^task_ref, outcome} ->
        Process.demonitor(task_ref, [:flush])
        outcome

      {:DOWN, ^task_ref, :process, _pid, reason} ->
        {:error, Sake.Plug.Stream.failure(:exit, reason, [])}
    end
  end

  # An answering function that throws gives up on the call, as on HTTP:
  # the handler is stopped, as a dropped stream stops it, and the throw
  # carries on (see `Sake.Client.Transport`).
  defp answer(session, task, request_id, method, params) do
    Transport.answer(session, request_id, method, params)
  catch
    :throw, value ->
      Task.shutdown(task, :brutal_kill)
      throw(value)
  end

  defp notify(session, notification) do
    %{"method" => method, "params" => params} = wire(notification)
    Transport.notify(session, method, params)
  end

  defp wire(message), do: message |> Sake.JSON.encode!() |> JSON.decode!()

  # ---- tasks

  @doc false
  # Waits up to `ms` before the client polls the task again, and returns
  # as soon as the task's status changes: the endpoint runs on this node,
  # so it can see the task's broadcasts instead of sleeping through them.
  # Whoever changes the task (its worker, a cancel from another process),
  # the broadcast names it, so the wait listens to all of the server's.
  @spec wait(Session.t(), map(), non_neg_integer()) :: :ok
  def wait(%Session{local: endpoint}, %{"taskId" => id, "status" => status}, ms) do
    if Process.whereis(Streams) do
      tag = make_ref()
      :ok = Streams.register_test(endpoint.server, :any, tag)

      # Registered before the store is read, so a change between the two
      # is not missed.
      unless changed?(id, status) do
        receive do
          {^tag, _server, {:task, %{"taskId" => ^id}}} -> :ok
        after
          ms -> :ok
        end
      end

      :ok = Streams.unregister_test(endpoint.server, :any, tag)
      flush(tag)
    else
      Process.sleep(ms)
    end
  end

  defp changed?(id, status) do
    case Sake.Tasks.fetch(id) do
      {:ok, record} -> Record.to_wire(record)["status"] != status
      :error -> true
    end
  end

  defp flush(tag) do
    receive do
      {^tag, _server, _event} -> flush(tag)
    after
      0 -> :ok
    end
  end
end
