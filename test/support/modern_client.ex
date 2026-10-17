defmodule SakeTest.ModernClient do
  @moduledoc false
  # Drives Sake.Plug through Plug.Test as a modern (2026-07-28) client.
  import Plug.Test
  import Plug.Conn

  @secret String.duplicate("s", 64)

  def secret, do: @secret

  def opts(overrides \\ []),
    do: Sake.Plug.init(Keyword.merge([server: SakeDev.Server, secret: @secret], overrides))

  @doc """
  Sends one request. `opts`: `:headers` (extra request headers), `:meta`
  (extra `_meta`), `:capabilities` (default `%{}`), `:version` (header and
  meta, default modern), `:mirror` (default true: Mcp-Method/Mcp-Name/Mcp-Param headers).
  """
  def post(plug_opts, method, params \\ %{}, opts \\ []) do
    version = Keyword.get(opts, :version, "2026-07-28")

    meta =
      %{
        "io.modelcontextprotocol/protocolVersion" => version,
        "io.modelcontextprotocol/clientCapabilities" => Keyword.get(opts, :capabilities, %{}),
        "io.modelcontextprotocol/clientInfo" => %{"name" => "test", "version" => "0"}
      }
      |> Map.merge(params["_meta"] || %{})
      |> Map.merge(Keyword.get(opts, :meta, %{}))

    params = Map.put(params, "_meta", meta)

    body =
      if Keyword.get(opts, :notification, false),
        do: Sake.JSONRPC.notification(method, params),
        else: Sake.JSONRPC.request(Keyword.get(opts, :id, 1), method, params)

    conn =
      conn(:post, "/mcp", JSON.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("mcp-protocol-version", version)
      # The host the request arrives with, as behind a proxy that sends
      # its upstream's.
      |> Map.update!(:host, &Keyword.get(opts, :host, &1))

    conn = if Keyword.get(opts, :mirror, true), do: mirror(conn, method, params, opts), else: conn

    conn =
      Enum.reduce(Keyword.get(opts, :headers, []), conn, fn {k, v}, c ->
        put_req_header(c, k, v)
      end)

    Sake.Plug.call(conn, plug_opts)
  end

  defp mirror(conn, method, params, opts) do
    conn = put_req_header(conn, "mcp-method", method)

    conn =
      case name_header(method, params) do
        nil -> conn
        name -> put_req_header(conn, "mcp-name", Sake.Plug.Headers.encode_value(name))
      end

    Enum.reduce(Keyword.get(opts, :params, []), conn, fn {name, value}, c ->
      put_req_header(
        c,
        "mcp-param-" <> String.downcase(name),
        Sake.Plug.Headers.encode_value(value)
      )
    end)
  end

  defp name_header("tools/call", params), do: params["name"] || ""
  defp name_header("prompts/get", params), do: params["name"] || ""
  defp name_header("resources/read", params), do: params["uri"] || ""
  defp name_header("tasks/" <> _, %{"taskId" => id}) when is_binary(id), do: id
  defp name_header(_method, _params), do: nil

  def json(conn), do: JSON.decode!(conn.resp_body)

  @doc "Parses an SSE body into the list of decoded `data` payloads."
  def events(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn block ->
      data =
        block
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "data: "))
        |> Enum.map_join("\n", &String.replace_prefix(&1, "data: ", ""))

      if data == "", do: [], else: [JSON.decode!(data)]
    end)
  end
end
