defmodule Sake.Plug.Body do
  @moduledoc false
  # The JSON body of a request. A Phoenix endpoint's `Plug.Parsers` (the
  # generated `:json` parser with `pass: ["*/*"]`) reads and decodes the
  # body before the request reaches Sake, so the raw body is gone: a JSON
  # object is then `conn.body_params` itself, and any other JSON value
  # (an array, for a batch) is under the `"_json"` key. When no parser ran,
  # or a parser let the content type pass without reading it (the params
  # are then an empty map), Sake reads and decodes the raw body itself.

  import Plug.Conn

  @spec json(Plug.Conn.t(), pos_integer()) ::
          {:ok, term(), Plug.Conn.t()} | {:error, :too_large | :json}
  def json(conn, limit) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} -> raw(conn, limit)
      params when params == %{} -> raw(conn, limit)
      %{"_json" => json} = params when map_size(params) == 1 -> {:ok, json, conn}
      params -> {:ok, params, conn}
    end
  end

  defp raw(conn, limit) do
    case read_body(conn, length: limit, read_length: limit) do
      {:ok, body, conn} -> decode(body, conn)
      {:more, _partial, _conn} -> {:error, :too_large}
      {:error, _} -> {:error, :json}
    end
  end

  defp decode(body, conn) do
    case JSON.decode(body) do
      {:ok, json} -> {:ok, json, conn}
      {:error, _} -> {:error, :json}
    end
  end
end
