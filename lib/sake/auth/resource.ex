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

  @spec scopes_string(Sake.Auth.Config.t()) :: String.t()
  def scopes_string(config),
    do: config |> Sake.Auth.Config.scopes() |> Enum.map_join(" ", &elem(&1, 0))
end
