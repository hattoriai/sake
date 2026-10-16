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

  @spec comment(Plug.Conn.t()) :: {:ok, Plug.Conn.t()} | {:error, term()}
  def comment(conn), do: chunk(conn, ":\n\n")
end
