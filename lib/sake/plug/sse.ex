defmodule Sake.Plug.SSE do
  @moduledoc false
  import Plug.Conn

  @spec start(Plug.Conn.t()) :: Plug.Conn.t()
  def start(conn) do
    conn
    |> put_resp_content_type("text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("x-accel-buffering", "no")
    |> send_chunked(200)
  end

  @spec event(Plug.Conn.t(), map()) :: {:ok, Plug.Conn.t()} | {:error, term()}
  def event(conn, message),
    do: chunk(conn, ["event: message\ndata: ", Sake.JSON.encode_to_iodata!(message), "\n\n"])

  @doc """
  Sends a stream's last event. Returns the conn whether or not the write
  succeeds: a client that has gone gets no answer, and nothing follows on
  the stream that needs to know.
  """
  @spec last_event(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def last_event(conn, message) do
    case event(conn, message) do
      {:ok, conn} -> conn
      {:error, _closed} -> conn
    end
  end

  @spec comment(Plug.Conn.t()) :: {:ok, Plug.Conn.t()} | {:error, term()}
  def comment(conn), do: chunk(conn, ":\n\n")
end
