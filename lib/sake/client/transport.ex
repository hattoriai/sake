defmodule Sake.Client.Transport do
  @moduledoc false
  # One HTTP round trip: JSON or SSE. `post/3` returns the final JSON-RPC
  # message for the request (or `:accepted` for notifications), after
  # answering any legacy elicitation requests seen on the stream. A legacy
  # `elicitation/create` request is keyed for `on_input` by
  # `params["_meta"]["ai.hattori.sake/key"]` when a Sake server sent it, or
  # by the fixed key `"legacy"` for a foreign server that omits it.

  alias Sake.Client.{Auth, Challenge, Session}
  alias Sake.JSONRPC
  alias Sake.Plug.Headers
  alias Sake.Protocol

  @accept "application/json, text/event-stream"
  @vendor_key "ai.hattori.sake/key"

  @spec post(Session.t(), map(), keyword()) ::
          {:ok, map() | :accepted, Session.t()} | {:error, term()}
  def post(session, message, opts \\ []) do
    headers =
      [{"accept", @accept}] ++
        era_headers(session, message, opts) ++ Auth.headers(session.auth, session.headers)

    id = message["id"]

    result =
      Req.post(
        session.url,
        [
          json: message,
          headers: headers,
          retry: false,
          decode_body: false,
          receive_timeout: Keyword.get(opts, :timeout, 300_000)
        ] ++
          session.req ++
          [into: fn {:data, data}, {req, resp} -> stream(data, {req, resp}, session, id) end]
      )

    case result do
      {:ok, %Req.Response{status: 401} = resp} ->
        {:error, {:unauthorized, challenge(resp)}}

      {:ok, %Req.Response{status: 403} = resp} ->
        forbidden(resp)

      {:ok, %Req.Response{status: 202}} ->
        {:ok, :accepted, session}

      {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
        finish(resp, session, id)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http, status, decode_maybe(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---- body handling: JSON bodies arrive as one chunk; SSE bodies as many

  defp stream(data, {req, resp}, session, id) do
    case content_type(resp) do
      :sse ->
        {events, buffer} = parse_sse((resp.private[:sake_buffer] || "") <> data)
        resp = put_in(resp.private[:sake_buffer], buffer)

        {resp, done?} =
          Enum.reduce(events, {resp, false}, fn event, {resp, done?} ->
            {handle_event(event, resp, session), done? or final?(event, id)}
          end)

        if done?, do: {:halt, {req, resp}}, else: {:cont, {req, resp}}

      :json ->
        {:cont, {req, %{resp | body: (resp.body || "") <> data}}}
    end
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
      {:request, rid, "elicitation/create", params} ->
        # The handler's key travels in `_meta` under our vendor prefix (see
        # `Sake.Elicit`); a foreign server that omits it falls back to the
        # fixed key `"legacy"`, since a legacy stream only ever asks one
        # question at a time.
        key = get_in(params, ["_meta", @vendor_key]) || "legacy"

        answer =
          if session.on_input,
            do:
              session.on_input.(
                %{key => %{"method" => "elicitation/create", "params" => params}},
                session
              )[key],
            else: %{"action" => "cancel"}

        _ = post(session, JSONRPC.result(rid, answer || %{"action" => "cancel"}))
        resp

      {:request, rid, _other, _} ->
        _ = post(session, JSONRPC.error(rid, JSONRPC.code(:method_not_found), "Method not found"))
        resp

      _ ->
        put_in(resp.private[:sake_events], (resp.private[:sake_events] || []) ++ [event])
    end
  end

  defp final?(event, id),
    do:
      is_map(event) and Map.has_key?(event, "id") and event["id"] == id and
        (Map.has_key?(event, "result") or Map.has_key?(event, "error"))

  defp finish(resp, session, id) do
    session = capture_session(resp, session)

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

  defp challenge(resp) do
    case Map.get(resp.headers, "www-authenticate") do
      [h | _] -> Challenge.parse(h)
      _ -> %Challenge{scheme: "Bearer"}
    end
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
  defp name_header(_, _), do: []

  defp param_headers(%Sake.Tool.Spec{headers: headers}, args) do
    for {name, path} <- headers,
        value = get_in(args, path),
        value != nil,
        do: {"mcp-param-" <> String.downcase(name), Headers.encode_value(value)}
  end

  defp param_headers(_, _), do: []

  @doc false
  def parse_sse(buffer) do
    case String.split(buffer, "\n\n") do
      [rest] ->
        {[], rest}

      blocks ->
        {complete, [rest]} = Enum.split(blocks, -1)
        {Enum.flat_map(complete, &decode_event_block/1), rest}
    end
  end

  defp decode_event_block(block) do
    data =
      block
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map_join("\n", &(&1 |> String.replace_prefix("data:", "") |> String.trim_leading()))

    case data != "" && JSON.decode(data) do
      {:ok, json} -> [json]
      _ -> []
    end
  end

  @doc false
  def delete(session) do
    headers =
      [{"mcp-session-id", session.session_id}] ++ Auth.headers(session.auth, session.headers)

    _ = Req.delete(session.url, [headers: headers, retry: false] ++ session.req)
    :ok
  end
end
