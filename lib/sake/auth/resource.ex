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

  @doc """
  The URL of the protected resource metadata (RFC 9728 §3.1) of the
  endpoint at `url` (an origin and a path), or that a request reached.
  """
  @spec metadata_url(String.t() | Plug.Conn.t()) :: String.t()
  def metadata_url(%Plug.Conn{} = conn), do: metadata_url(url(conn))

  def metadata_url(url) do
    [_, origin, path] = Regex.run(~r{\A([^:/]+://[^/]*)(.*)\z}s, url)
    origin <> "/.well-known/oauth-protected-resource" <> String.trim_trailing(path, "/")
  end

  @doc "The URL a request reached: its origin and path, without the query."
  @spec url(Plug.Conn.t()) :: String.t()
  def url(conn), do: origin(conn) <> conn.request_path

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
