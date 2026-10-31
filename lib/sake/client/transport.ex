defmodule Sake.Client.Transport do
  @moduledoc false
  # One HTTP round trip: JSON or SSE. `post/3` returns the final JSON-RPC
  # message for the request (or `:accepted` for notifications), after
  # answering any legacy server requests seen on the stream (elicitation,
  # sampling, roots; see `Sake.Client.Inputs`). A legacy request is keyed
  # by `params["_meta"]["ai.hattori.sake/key"]` when a Sake server sent it,
  # or by the fixed key `"legacy"` for a foreign server that omits it. A
  # stdio session's messages go to `Sake.Client.Stdio` instead, and an
  # in-memory session's to `Sake.Test.Endpoint`.
  #
  # An answering function may throw to give up on the call (`Sake.Proxy`
  # does, to pass a legacy server's question on to a modern client, which
  # answers it on a retry): the question goes unanswered, the stream is
  # dropped, which tells the server the call was abandoned, and the throw
  # carries on from `post/3`, out of Req.

  alias Sake.Auth.Challenge
  alias Sake.Client.{Auth, Inputs, Session}
  alias Sake.JSONRPC
  alias Sake.Plug.Headers
  alias Sake.Protocol

  @accept "application/json, text/event-stream"
  @vendor_key "ai.hattori.sake/key"

  @spec post(Session.t(), map(), keyword()) ::
          {:ok, map() | :accepted, Session.t()} | {:error, term()}
  def post(session, message, opts \\ [])

  def post(%Session{stdio: pid} = session, message, opts) when is_pid(pid),
    do: Sake.Client.Stdio.post(session, message, opts)

  def post(%Session{local: endpoint} = session, message, opts) when endpoint != nil,
    do: Sake.Test.Endpoint.post(session, message, opts)

  def post(session, message, opts) do
    headers =
      [{"accept", @accept}, {"content-type", "application/json"}] ++
        era_headers(session, message, opts) ++
        Auth.headers(session.auth, "POST", session.url, session.headers)

    id = message["id"]
    cursor = make_ref()

    result =
      Req.post(
        session.url,
        [
          # Not Req's `json:`, which always encodes with Jason: the
          # message carries the host's arguments, for the configured library.
          body: Sake.JSON.encode_to_iodata!(message),
          headers: headers,
          retry: false,
          decode_body: false,
          receive_timeout: Keyword.get(opts, :timeout, 300_000)
        ] ++
          session.req ++
          [into: fn {:data, data}, acc -> stream(data, acc, session, id, cursor) end]
      )

    case resumable(result, session, id, Process.delete(cursor)) do
      {:resume, session, last} -> resume(session, id, last, opts, 1)
      :no -> outcome(result, session, id)
    end
  end

  defp outcome(result, session, id) do
    case result do
      {:ok, %Req.Response{private: %{sake_throw: {:throw, value}}}} ->
        throw(value)

      {:ok, %Req.Response{private: %{sake_too_large: true}}} ->
        {:error, :response_too_large}

      {:ok, %Req.Response{status: 401} = resp} ->
        unauthorized(resp)

      {:ok, %Req.Response{status: 403} = resp} ->
        forbidden(resp)

      {:ok, %Req.Response{status: 202} = resp} ->
        {:ok, :accepted, capture_nonce(resp, session)}

      {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
        finish(resp, session, id)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http, status, decode_maybe(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---- resumability (legacy revisions, "Resumability and Redelivery")
  #
  # A legacy server may number its SSE events and end a call's stream
  # before the response (a dropped connection, or the 2025-11-25 polling
  # pattern, where it closes the stream on purpose after a `retry:`). The
  # client then waits `retry` ms (or a backoff of its own), and asks for
  # the rest of the stream with a GET carrying `Last-Event-ID`, up to
  # `max_reconnects` times in a row without an event in between.

  # A stream that ended without the call's response, after an event ID.
  defp resumable(result, %Session{era: :legacy} = session, id, %{id: last} = cursor)
       when is_binary(last) and id != nil do
    case result do
      {:ok, %Req.Response{status: 200, private: private} = resp}
      when not is_map_key(private, :sake_throw) and not is_map_key(private, :sake_too_large) ->
        if content_type(resp) == :sse and
             not Enum.any?(private[:sake_events] || [], &final?(&1, id)),
           do:
             {:resume, resp |> capture_session(session) |> then(&capture_nonce(resp, &1)), cursor},
           else: :no

      {:error, _reason} ->
        {:resume, session, cursor}

      _ ->
        :no
    end
  end

  defp resumable(_result, _session, _id, _cursor), do: :no

  defp resume(session, _id, _last, _opts, attempt) when attempt > session.max_reconnects,
    do: {:error, :stream_lost}

  defp resume(session, id, last, opts, attempt) do
    Process.sleep(last[:retry] || backoff(attempt))

    headers =
      [{"accept", "text/event-stream"}, {"last-event-id", last.id}] ++
        era_headers(session, %{}, []) ++
        Auth.headers(session.auth, "GET", session.url, session.headers)

    cursor = make_ref()
    Process.put(cursor, last)

    result =
      Req.get(
        session.url,
        [
          headers: headers,
          retry: false,
          decode_body: false,
          receive_timeout: Keyword.get(opts, :timeout, 300_000)
        ] ++
          session.req ++
          [into: fn {:data, data}, acc -> stream(data, acc, session, id, cursor) end]
      )

    next = Process.delete(cursor)
    # Each event received makes a new run of attempts.
    attempt = if next.id == last.id, do: attempt + 1, else: 1

    case resumable(result, session, id, next) do
      {:resume, session, next} -> resume(session, id, next, opts, attempt)
      :no -> outcome(result, session, id)
    end
  end

  defp backoff(attempt), do: min(1_000 * Integer.pow(2, attempt - 1), 30_000)

  # ---- body handling: JSON bodies arrive as one chunk; SSE bodies as many

  # Neither a JSON body nor an event still being received may grow past
  # the session's `max_response_size`: the request stops there.
  defp stream(data, {req, resp}, session, id, cursor) do
    case content_type(resp) do
      :sse ->
        stream_sse(data, {req, resp}, session, id, cursor)

      :json ->
        body = (resp.body || "") <> data

        if byte_size(body) > session.max_response_size,
          do: too_large(req, resp),
          else: {:cont, {req, %{resp | body: body}}}
    end
  end

  defp stream_sse(data, {req, resp}, session, id, cursor) do
    {fields, buffer} = parse_sse_fields((resp.private[:sake_buffer] || "") <> data)
    resp = put_in(resp.private[:sake_buffer], buffer)
    track(cursor, fields)
    events = for %{data: json} <- fields, json != nil, do: json

    {resp, done?} = handle_events(events, resp, session, id)

    cond do
      done? -> {:halt, {req, resp}}
      byte_size(buffer) > session.max_response_size -> too_large(req, resp)
      true -> {:cont, {req, resp}}
    end
  end

  defp too_large(req, resp), do: {:halt, {req, put_in(resp.private[:sake_too_large], true)}}

  # An abandoned call reads no further.
  defp handle_events(events, resp, session, id) do
    Enum.reduce_while(events, {resp, false}, fn event, {resp, done?} ->
      resp = handle_event(event, resp, session)

      if Map.has_key?(resp.private, :sake_throw),
        do: {:halt, {resp, true}},
        else: {:cont, {resp, done? or final?(event, id)}}
    end)
  end

  defp content_type(resp) do
    if resp.headers
       |> Map.get("content-type", [])
       |> Enum.any?(&String.contains?(&1, "text/event-stream")),
       do: :sse,
       else: :json
  end

  defp handle_event(event, resp, session) do
    case JSONRPC.parse(event) do
      {:request, rid, method, params} ->
        answer_on_stream(session, rid, method, params, resp)

      {:notification, method, params} ->
        notify(session, method, params)
        collect(resp, event)

      _ ->
        collect(resp, event)
    end
  end

  defp answer_on_stream(session, rid, method, params, resp) do
    _ = post(session, answer(session, rid, method, params))
    resp
  catch
    :throw, value -> put_in(resp.private[:sake_throw], {:throw, value})
  end

  defp collect(resp, event),
    do: put_in(resp.private[:sake_events], (resp.private[:sake_events] || []) ++ [event])

  @doc false
  # Waits `ms` before a task is polled again. The in-memory endpoint sees
  # the task itself, and ends the wait as soon as its status changes.
  @spec wait(Session.t(), map(), non_neg_integer()) :: :ok
  def wait(%Session{local: endpoint} = session, task, ms) when endpoint != nil,
    do: Sake.Test.Endpoint.wait(session, task, ms)

  def wait(_session, _task, ms), do: Process.sleep(ms)

  @doc false
  # The client's response to a legacy server's request, on any transport.
  @spec answer(Session.t(), JSONRPC.id(), String.t(), map()) :: map()
  def answer(session, rid, method, params) do
    # The handler's key travels in `_meta` under our vendor prefix (see
    # `Sake.Elicit`); a foreign server that omits it falls back to the
    # fixed key `"legacy"`, since a legacy stream only ever asks one
    # question at a time.
    key = get_in(params, ["_meta", @vendor_key]) || "legacy"
    requests = %{key => %{"method" => method, "params" => params}}
    reply(rid, Inputs.answer(session, requests)[key])
  end

  defp reply(rid, {:ok, result}), do: JSONRPC.result(rid, result)
  defp reply(rid, {:error, error}), do: %{"jsonrpc" => "2.0", "id" => rid, "error" => error}

  defp reply(rid, nil),
    do: JSONRPC.error(rid, JSONRPC.code(:method_not_found), "Method not found")

  @doc false
  # A notification the server sent during a call, for `on_notification`.
  @spec notify(Session.t(), String.t(), map()) :: :ok
  def notify(%Session{on_notification: nil}, _method, _params), do: :ok

  def notify(%Session{on_notification: fun}, method, params) do
    fun.(method, params)
    :ok
  end

  defp final?(event, id),
    do:
      is_map(event) and Map.has_key?(event, "id") and event["id"] == id and
        (Map.has_key?(event, "result") or Map.has_key?(event, "error"))

  defp finish(resp, session, id) do
    session = resp |> capture_session(session) |> then(&capture_nonce(resp, &1))

    case content_type(resp) do
      :sse ->
        case Enum.find(resp.private[:sake_events] || [], &final?(&1, id)) do
          nil -> {:error, :no_response}
          message -> {:ok, message, session}
        end

      :json ->
        case JSON.decode(resp.body || "") do
          {:ok, message} -> {:ok, message, session}
          _ -> {:error, {:http, resp.status, resp.body}}
        end
    end
  end

  defp capture_session(resp, session) do
    case Map.get(resp.headers, "mcp-session-id") do
      [sid | _] -> %{session | session_id: sid}
      _ -> session
    end
  end

  # A server that takes DPoP sends a challenge for each scheme (RFC 9449
  # §7.1), the one with the error first; a nonce request is looked for in
  # all of them, so a server that orders them otherwise is still heard.
  defp challenge(resp) do
    challenges = Enum.map(Map.get(resp.headers, "www-authenticate", []), &Challenge.parse/1)
    nonce = resp.headers |> Map.get("dpop-nonce", []) |> List.first()

    challenge =
      Enum.find(challenges, &(&1.error == "use_dpop_nonce")) || List.first(challenges) ||
        %Challenge{scheme: "Bearer"}

    %{challenge | nonce: nonce}
  end

  # The server's latest DPoP nonce, from any answer that carries one.
  defp capture_nonce(resp, %Session{auth: auth} = session) when auth != nil do
    case Map.get(resp.headers, "dpop-nonce") do
      [nonce | _] -> %{session | auth: Auth.put_nonce(auth, session.url, nonce)}
      _ -> session
    end
  end

  defp capture_nonce(_resp, session), do: session

  # The GET stream and the DELETE are not retried by `Sake.Client`'s own
  # authorization loop; a DPoP nonce challenge on either gets the request
  # once more here, with the nonce.
  defp with_nonce(session, request) do
    case request.(session) do
      {:error, {:unauthorized, %Challenge{error: "use_dpop_nonce", nonce: nonce}}}
      when is_binary(nonce) ->
        session |> Map.update!(:auth, &Auth.put_nonce(&1, session.url, nonce)) |> request.()

      other ->
        other
    end
  end

  # RFC 9470: a token refused for how its person signed in, which a new
  # sign-in (and a new grant) may cure, where another 401 asks for a
  # token at all.
  defp unauthorized(resp) do
    c = challenge(resp)

    if c.error == "insufficient_user_authentication",
      do: {:error, {:insufficient_user_authentication, c}},
      else: {:error, {:unauthorized, c}}
  end

  defp forbidden(resp) do
    c = challenge(resp)

    if c.error == "insufficient_scope",
      do: {:error, {:insufficient_scope, c}},
      else: {:error, {:http, 403, decode_maybe(resp.body)}}
  end

  defp decode_maybe(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, j} -> j
      _ -> body
    end
  end

  defp decode_maybe(body), do: body

  defp era_headers(%Session{era: :modern} = s, %{"method" => method} = message, opts) do
    params = message["params"] || %{}

    [{"mcp-protocol-version", s.revision || Protocol.modern()}, {"mcp-method", method}] ++
      name_header(method, params) ++
      param_headers(opts[:tool], params["arguments"] || %{})
  end

  defp era_headers(%Session{era: :legacy, revision: rev, session_id: sid}, _message, _opts) do
    if(rev && rev != "2025-03-26", do: [{"mcp-protocol-version", rev}], else: []) ++
      if(sid, do: [{"mcp-session-id", sid}], else: [])
  end

  defp era_headers(%Session{era: nil} = s, message, opts),
    do: era_headers(%{s | era: :modern}, message, opts)

  defp name_header("tools/call", %{"name" => n}), do: [{"mcp-name", Headers.encode_value(n)}]
  defp name_header("prompts/get", %{"name" => n}), do: [{"mcp-name", Headers.encode_value(n)}]
  defp name_header("resources/read", %{"uri" => u}), do: [{"mcp-name", Headers.encode_value(u)}]

  defp name_header("tasks/" <> _, %{"taskId" => id}) when is_binary(id),
    do: [{"mcp-name", Headers.encode_value(id)}]

  defp name_header(_, _), do: []

  # The value is bound through a one-element generator: a bare `value =`
  # line in a comprehension is also a filter, and would drop `false`.
  defp param_headers(%Sake.Tool.Spec{headers: headers}, args) do
    for {name, path} <- headers,
        value <- [get_in(args, path)],
        value != nil,
        do: {"mcp-param-" <> String.downcase(name), Headers.encode_value(value)}
  end

  defp param_headers(_, _), do: []

  # The last event ID and `retry` seen on a stream, kept in the process
  # dictionary: they must outlive a stream that ends in a transport error.
  defp track(cursor, fields) do
    Process.put(
      cursor,
      Enum.reduce(fields, Process.get(cursor) || %{id: nil}, fn field, acc ->
        acc
        |> then(&if(field.id, do: %{&1 | id: nonempty(field.id)}, else: &1))
        |> then(&if(field.retry, do: Map.put(&1, :retry, field.retry), else: &1))
      end)
    )
  end

  # An empty ID resets the last event ID (the SSE spec).
  defp nonempty(""), do: nil
  defp nonempty(id), do: id

  @doc false
  # The JSON messages of the complete events in `buffer`, and the rest.
  def parse_sse(buffer) do
    {fields, rest} = parse_sse_fields(buffer)
    {for(%{data: json} <- fields, json != nil, do: json), rest}
  end

  @doc false
  # Events end at a blank line, lines at CRLF, LF or CR (the SSE spec):
  # line ends become LF first. A CR at the very end of the buffer may be
  # the first half of a CRLF split across chunks, so it waits for the next.
  # Each complete event is `%{id:, retry:, data:}`: its ID and `retry`
  # (`nil` when absent) and its JSON message (`nil` for none, as in a
  # priming event).
  def parse_sse_fields(buffer) do
    {buffer, cr} =
      if String.ends_with?(buffer, "\r"),
        do: {binary_part(buffer, 0, byte_size(buffer) - 1), "\r"},
        else: {buffer, ""}

    buffer = buffer |> String.replace("\r\n", "\n") |> String.replace("\r", "\n")

    case String.split(buffer, "\n\n") do
      [rest] ->
        {[], rest <> cr}

      blocks ->
        {complete, [rest]} = Enum.split(blocks, -1)
        {Enum.flat_map(complete, &decode_event_block/1), rest <> cr}
    end
  end

  defp decode_event_block(block) do
    lines = String.split(block, "\n")

    case %{id: event_id(lines), retry: event_retry(lines), data: event_data(lines)} do
      %{id: nil, retry: nil, data: nil} -> []
      event -> [event]
    end
  end

  defp event_data(lines) do
    data = lines |> Enum.flat_map(&field(&1, "data")) |> Enum.join("\n")

    case data != "" && JSON.decode(data) do
      {:ok, json} -> json
      _ -> nil
    end
  end

  # An ID with a NUL is ignored (the SSE spec), as is a `retry` that is
  # not all digits.
  defp event_id(lines) do
    lines
    |> Enum.flat_map(&field(&1, "id"))
    |> Enum.reject(&String.contains?(&1, <<0>>))
    |> List.last()
  end

  defp event_retry(lines) do
    lines
    |> Enum.flat_map(&field(&1, "retry"))
    |> Enum.filter(&(&1 =~ ~r/\A\d+\z/))
    |> Enum.map(&String.to_integer/1)
    |> List.last()
  end

  # A field's value: after the name and a colon, one leading space dropped.
  defp field(line, name) do
    cond do
      line == name ->
        [""]

      String.starts_with?(line, name <> ":") ->
        [line |> String.replace_prefix(name <> ":", "") |> String.replace_prefix(" ", "")]

      true ->
        []
    end
  end

  @doc false
  # A legacy session's own notifications, until the server ends the
  # stream: its GET stream on HTTP, what the server sends between calls on
  # stdio. Keepalive comments arrive at least every few seconds, so a
  # stream silent for a minute is gone.
  # `opened` runs once the stream is open, on HTTP.
  @spec listen(Session.t(), (String.t(), map() -> any()), (-> any())) :: :ok | {:error, term()}
  def listen(%Session{stdio: pid}, fun, _opened) when is_pid(pid),
    do: Sake.Client.Stdio.listen(pid, fun)

  def listen(%Session{local: endpoint}, _fun, _opened) when endpoint != nil,
    do: {:error, :unsupported}

  def listen(session, fun, opened), do: with_nonce(session, &get_stream(&1, fun, opened))

  defp get_stream(session, fun, opened) do
    headers =
      [{"accept", "text/event-stream"}] ++
        era_headers(session, %{}, []) ++
        Auth.headers(session.auth, "GET", session.url, session.headers)

    result =
      Req.get(
        session.url,
        [headers: headers, retry: false, decode_body: false, receive_timeout: 60_000] ++
          session.req ++
          [into: &listened(&1, &2, fun, opened, session.max_response_size)]
      )

    case result do
      {:ok, %Req.Response{private: %{sake_too_large: true}}} -> {:error, :response_too_large}
      {:ok, %Req.Response{status: 200}} -> :ok
      {:ok, %Req.Response{status: 401} = resp} -> {:error, {:unauthorized, challenge(resp)}}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp listened({:data, data}, {req, resp}, fun, opened, max) do
    if resp.status == 200 do
      if !resp.private[:sake_opened], do: opened.()
      resp = put_in(resp.private[:sake_opened], true)
      {events, buffer} = parse_sse((resp.private[:sake_buffer] || "") <> data)

      for event <- events,
          {:notification, method, params} <- [JSONRPC.parse(event)],
          do: fun.(method, params)

      resp = put_in(resp.private[:sake_buffer], buffer)
      if byte_size(buffer) > max, do: too_large(req, resp), else: {:cont, {req, resp}}
    else
      body = (resp.body || "") <> data

      if byte_size(body) > max,
        do: too_large(req, resp),
        else: {:cont, {req, %{resp | body: body}}}
    end
  end

  @doc false
  def delete(session) do
    _ = with_nonce(session, &delete_once/1)
    :ok
  end

  defp delete_once(session) do
    headers =
      [{"mcp-session-id", session.session_id}] ++
        Auth.headers(session.auth, "DELETE", session.url, session.headers)

    case Req.delete(session.url, [headers: headers, retry: false] ++ session.req) do
      {:ok, %Req.Response{status: 401} = resp} -> {:error, {:unauthorized, challenge(resp)}}
      other -> other
    end
  end
end
