defmodule Sake.Auth.Resource do
  @moduledoc false
  # The canonical URL of the endpoint a request hits: the token audience.

  @spec canonical(Plug.Conn.t(), map()) :: String.t()
  def canonical(conn, %{resource: fun}) when is_function(fun, 1), do: fun.(conn)
  def canonical(conn, _opts), do: origin(conn) <> String.trim_trailing(conn.request_path, "/")

  @spec origin(Plug.Conn.t()) :: String.t()
  def origin(conn) do
    default = if conn.scheme == :https, do: 443, else: 80
    port = if conn.port in [default, nil], do: "", else: ":#{conn.port}"
    String.downcase("#{conn.scheme}://#{conn.host}") <> port
  end

  @spec metadata_url(Plug.Conn.t()) :: String.t()
  def metadata_url(conn),
    do:
      origin(conn) <>
        "/.well-known/oauth-protected-resource" <> String.trim_trailing(conn.request_path, "/")

  @spec scopes_string(Sake.Auth.Config.t() | Sake.Auth.External.t()) :: String.t()
  def scopes_string(config),
    do: config |> Sake.Auth.Config.scopes() |> Enum.map_join(" ", &elem(&1, 0))

  @doc "Whether an endpoint path matches a pattern of `resources:` (`:param` segments match any one segment)."
  @spec path_match?(String.t(), String.t()) :: boolean()
  def path_match?(pattern, path) do
    ps = String.split(pattern, "/", trim: true)
    xs = String.split(path, "/", trim: true)

    length(ps) == length(xs) and
      Enum.zip(ps, xs) |> Enum.all?(fn {p, x} -> String.starts_with?(p, ":") or p == x end)
  end
end
