defmodule Sake.Plug.ClosedStreamTest.Adapter do
  @moduledoc false
  # Plug's test adapter, except that a chunk fails as on a connection the
  # client has closed, once the process's `:chunks_left` writes have
  # succeeded.
  alias Plug.Adapters.Test.Conn, as: Test

  def chunk(payload, body) do
    case Process.get(:chunks_left, 0) do
      0 ->
        {:error, :closed}

      n ->
        Process.put(:chunks_left, n - 1)
        Test.chunk(payload, body)
    end
  end

  defdelegate send_resp(payload, status, headers, body), to: Test
  defdelegate send_file(payload, status, headers, path, offset, length), to: Test
  defdelegate send_chunked(payload, status, headers), to: Test
  defdelegate read_req_body(payload, opts), to: Test
  defdelegate inform(payload, status, headers), to: Test
  defdelegate upgrade(payload, protocol, opts), to: Test
  defdelegate push(payload, path, headers), to: Test
  defdelegate get_peer_data(payload), to: Test
  defdelegate get_sock_data(payload), to: Test
  defdelegate get_ssl_data(payload), to: Test
  defdelegate get_http_protocol(payload), to: Test
end

defmodule Sake.Plug.ClosedStreamTest do
  # A client that closes its connection before a stream's last event: the
  # plug must still return the conn, as Bandit and Phoenix require of
  # every plug, instead of the failed write's error.
  use ExUnit.Case, async: false
  import Plug.Conn

  alias Sake.Plug.ClosedStreamTest.Adapter
  alias SakeTest.ModernClient

  defp request(method, params, chunks_left) do
    body =
      Sake.JSONRPC.request(
        1,
        method,
        Map.put(params, "_meta", %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{},
          "progressToken" => "p1"
        })
      )

    conn =
      Plug.Test.conn(:post, "/mcp", JSON.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("mcp-protocol-version", "2026-07-28")
      |> put_req_header("mcp-method", method)

    conn = if params["name"], do: put_req_header(conn, "mcp-name", params["name"]), else: conn
    {_test, payload} = conn.adapter
    Process.put(:chunks_left, chunks_left)
    Sake.Plug.call(%{conn | adapter: {Adapter, payload}}, ModernClient.opts())
  end

  test "a call's stream whose client has gone returns the conn" do
    # No progress before the result: the result is the stream's first
    # and last event, and its write fails.
    conn = request("tools/call", %{"name" => "echo", "arguments" => %{"text" => "hi"}}, 0)

    assert %Plug.Conn{state: :chunked} = conn
  end

  test "a listen stream told to shut down after its client has gone returns the conn" do
    stream =
      Task.async(fn ->
        # The acknowledgement goes out; the final result does not.
        request("subscriptions/listen", %{"notifications" => %{"toolsListChanged" => true}}, 1)
      end)

    await_listening(stream.pid)
    send(stream.pid, :sake_shutdown)

    assert %Plug.Conn{state: :chunked} = Task.await(stream)
  end

  defp await_listening(pid, attempts \\ 100) do
    listening? =
      Sake.Plug.Streams
      |> Registry.lookup({SakeDev.Server, :listen})
      |> Enum.any?(fn {registered, _} -> registered == pid end)

    cond do
      listening? ->
        :ok

      attempts == 0 ->
        flunk("the listen stream never registered")

      true ->
        Process.sleep(10)
        await_listening(pid, attempts - 1)
    end
  end
end
