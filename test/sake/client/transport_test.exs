defmodule Sake.Client.TransportTest do
  # What a server sends is read within bounds, and Server-Sent Events with
  # any of the line ends the SSE spec allows (issue #45).
  use ExUnit.Case, async: true

  alias Sake.Client.{Session, Transport}
  alias SakeTest.HTTP

  defmodule Server do
    @moduledoc false
    # Answers every POST as its path says.
    import Plug.Conn

    def init(opts), do: opts

    def call(%{request_path: "/big-json"} = conn, _opts) do
      body =
        ~s({"jsonrpc":"2.0","id":1,"result":{"text":") <> String.duplicate("x", 2_000) <> ~s("}})

      conn |> put_resp_content_type("application/json") |> send_resp(200, body)
    end

    # An event that never ends.
    def call(%{request_path: "/endless-event"} = conn, _opts) do
      conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)
      {:ok, conn} = chunk(conn, "data: ")

      Enum.reduce_while(1..100, conn, fn _, conn ->
        case chunk(conn, String.duplicate("x", 100)) do
          {:ok, conn} -> {:cont, conn}
          {:error, _} -> {:halt, conn}
        end
      end)
    end

    # CRLF line ends, the final event split across chunks in the middle of
    # a CRLF.
    def call(%{request_path: "/crlf"} = conn, _opts) do
      conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)
      progress = ~s({"jsonrpc":"2.0","method":"notifications/progress","params":{"progress":1}})
      result = ~s({"jsonrpc":"2.0","id":1,"result":{"ok":true}})
      {:ok, conn} = chunk(conn, "event: message\r\ndata: " <> progress <> "\r\n\r\n")
      {:ok, conn} = chunk(conn, "data: " <> result <> "\r\n\r")
      {:ok, conn} = chunk(conn, "\n")
      conn
    end
  end

  defp session(url, max \\ 1_024),
    do: %Session{
      url: url,
      era: :modern,
      revision: "2026-07-28",
      max_response_size: max,
      on_notification: fn method, params -> send(self(), {:notified, method, params}) end
    }

  defp post(url, path, max \\ 1_024),
    do: Transport.post(session(url <> path, max), Sake.JSONRPC.request(1, "ping", %{}))

  setup do
    %{url: HTTP.start(Server)}
  end

  test "a JSON body over max_response_size ends the request", %{url: url} do
    assert {:error, :response_too_large} = post(url, "/big-json")
    assert {:ok, %{"result" => %{"text" => _}}, _} = post(url, "/big-json", 4_096)
  end

  test "an event growing past max_response_size ends the request", %{url: url} do
    assert {:error, :response_too_large} = post(url, "/endless-event")
  end

  test "events with CRLF line ends are read, a CRLF split across chunks included", %{url: url} do
    assert {:ok, %{"id" => 1, "result" => %{"ok" => true}}, _} = post(url, "/crlf")
  end

  describe "parse_sse/1" do
    test "LF, CRLF and CR line ends" do
      for sep <- ["\n", "\r\n", "\r"] do
        input =
          "data: {\"a\":1}" <> sep <> sep <> "data: {\"b\":2}" <> sep <> sep <> "data: {\"c\""

        assert {[%{"a" => 1}, %{"b" => 2}], "data: {\"c\""} = Transport.parse_sse(input)
      end
    end

    test "a CR at the end waits for what follows it" do
      assert {[], rest} = Transport.parse_sse("data: {\"a\":1}\r\n\r")
      assert {[%{"a" => 1}], ""} = Transport.parse_sse(rest <> "\n")
    end

    test "multi-line data is joined" do
      assert {[%{"a" => [1, 2]}], ""} =
               Transport.parse_sse("data: {\"a\":\r\ndata: [1,2]}\r\n\r\n")
    end
  end
end
