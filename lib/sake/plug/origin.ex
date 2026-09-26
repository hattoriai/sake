defmodule Sake.Plug.Origin do
  @moduledoc false

  @spec allowed?(Plug.Conn.t(), :any | [String.t()] | nil) :: boolean()
  def allowed?(conn, origins) do
    case Plug.Conn.get_req_header(conn, "origin") do
      [] -> true
      [origin | _] -> origins == :any or String.downcase(origin) in allowed(conn, origins)
    end
  end

  defp allowed(conn, nil), do: [own(conn)]
  defp allowed(conn, list), do: Enum.map(list, &String.downcase/1) ++ [own(conn)]

  defp own(conn) do
    default = if conn.scheme == :https, do: 443, else: 80
    port = if conn.port in [default, nil], do: "", else: ":#{conn.port}"
    String.downcase("#{conn.scheme}://#{conn.host}#{port}")
  end
end
