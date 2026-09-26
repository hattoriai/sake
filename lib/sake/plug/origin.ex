defmodule Sake.Plug.Origin do
  @moduledoc false

  # A request with no Origin header at all is always allowed: only a
  # browser sends one, so a non-browser MCP client (Claude Code, a CLI, a
  # server-to-server integration) is never affected by this check. A
  # request that *does* carry one must be allowed on purpose — there is no
  # "own origin", derived from the request's own (attacker-controllable)
  # Host header, standing in for an implicit default; a browser client
  # needs `origins:` configured.
  @spec allowed?(Plug.Conn.t(), :any | [String.t()] | nil) :: boolean()
  def allowed?(conn, origins) do
    case Plug.Conn.get_req_header(conn, "origin") do
      [] -> true
      [origin | _] -> origins == :any or String.downcase(origin) in allowed(origins)
    end
  end

  defp allowed(nil), do: []
  defp allowed(list) when is_list(list), do: Enum.map(list, &String.downcase/1)
end
