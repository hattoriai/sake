defmodule Sake.Plug.Stream do
  @moduledoc false
  # Runs one request and writes its response.

  @spec respond(Plug.Conn.t(), map(), Sake.JSONRPC.parsed(), Sake.Context.t(), function()) ::
          Plug.Conn.t()
  def respond(conn, _opts, {:request, id, _method, _params} = parsed, ctx, handler) do
    Sake.Plug.outcome_to_response(conn, id, handler.(ctx.server, parsed, ctx))
  end

  @spec legacy(Plug.Conn.t(), map(), map(), String.t()) :: Plug.Conn.t()
  def legacy(conn, _opts, _session, _id), do: Plug.Conn.send_resp(conn, 405, "")

  @spec client_response(
          Plug.Conn.t(),
          map(),
          Sake.Context.t(),
          term(),
          {:ok, map()} | {:error, map()}
        ) :: Plug.Conn.t()
  def client_response(conn, _opts, _ctx, _id, _response), do: Plug.Conn.send_resp(conn, 202, "")
end
