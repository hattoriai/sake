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

  @doc "Sends an event with its ID, for a client to resume after (`Last-Event-ID`)."
  @spec event(Plug.Conn.t(), map(), String.t()) :: {:ok, Plug.Conn.t()} | {:error, term()}
  def event(conn, message, id) do
    chunk(conn, [
      "event: message\nid: ",
      id,
      "\ndata: ",
      Sake.JSON.encode_to_iodata!(message),
      "\n\n"
    ])
  end

  @doc """
  Opens a resumable stream: how long a client waits before it reconnects
  (`retry:`). On 2025-11-25, the priming event too (an ID and empty
  data), so a client can resume before any other event arrived; a client
  of an earlier revision expects no empty event, and gets a comment.
  """
  @spec prime(Plug.Conn.t(), String.t(), pos_integer(), String.t()) ::
          {:ok, Plug.Conn.t()} | {:error, term()}
  def prime(conn, id, retry, revision) when revision >= "2025-11-25",
    do: chunk(conn, ["id: ", id, "\nretry: ", Integer.to_string(retry), "\ndata: \n\n"])

  def prime(conn, _id, retry, _revision),
    do: chunk(conn, ["retry: ", Integer.to_string(retry), "\n\n:\n\n"])
end
