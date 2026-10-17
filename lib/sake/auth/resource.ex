defmodule Sake.Auth.Resource do
  @moduledoc false
  # The canonical URL of the endpoint a request hits: the token audience.

  alias Sake.Auth.{Config, External}

  @spec canonical(Plug.Conn.t(), Config.t() | External.t(), map()) :: String.t()
  def canonical(conn, _config, %{resource: fun}) when is_function(fun, 1), do: fun.(conn)

  def canonical(conn, config, _opts),
    do: origin(conn, config) <> String.trim_trailing(conn.request_path, "/")

  @doc """
  The origin clients reach the endpoints of `config`'s authorization
  server at. Sake's own serves only its issuer's origin, so that is it,
  whatever host the request arrived with (a proxy's upstream address,
  say); an external one's is its `url:`, else the request's.
  """
  @spec origin(Plug.Conn.t(), Config.t() | External.t()) :: String.t()
  def origin(_conn, %Config{} = config), do: issuer_origin(config)
  def origin(_conn, %External{url: url}) when is_binary(url), do: url
  def origin(conn, %External{}), do: origin(conn)

  @doc "The origin of Sake's own issuer: the one origin its resources are on."
  @spec issuer_origin(Config.t()) :: String.t()
  def issuer_origin(%Config{issuer: issuer}), do: url_origin(issuer)

  @doc "The origin of a URL: its scheme, host and port when not the scheme's default."
  @spec url_origin(String.t()) :: String.t()
  def url_origin(url) do
    uri = URI.parse(url)
    port = if uri.port in [URI.default_port(uri.scheme), nil], do: "", else: ":#{uri.port}"
    String.downcase("#{uri.scheme}://#{uri.host}") <> port
  end

  @doc "The origin of the request itself, from its host, scheme and port."
  @spec origin(Plug.Conn.t()) :: String.t()
  def origin(conn) do
    default = if conn.scheme == :https, do: 443, else: 80
    port = if conn.port in [default, nil], do: "", else: ":#{conn.port}"
    String.downcase("#{conn.scheme}://#{conn.host}") <> port
  end

  @doc """
  The URL of the protected resource metadata (RFC 9728 §3.1) of the
  endpoint at `url` (an origin and a path).
  """
  @spec metadata_url(String.t()) :: String.t()
  def metadata_url(url) do
    [_, origin, path] = Regex.run(~r{\A([^:/]+://[^/]*)(.*)\z}s, url)
    origin <> "/.well-known/oauth-protected-resource" <> String.trim_trailing(path, "/")
  end

  @doc "The URL a request reached, as the client sees it: `origin/2` and the path, without the query."
  @spec url(Plug.Conn.t(), Config.t() | External.t()) :: String.t()
  def url(conn, config), do: origin(conn, config) <> conn.request_path

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
