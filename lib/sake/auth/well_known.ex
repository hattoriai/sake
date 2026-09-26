defmodule Sake.Auth.WellKnown do
  @moduledoc """
  Serves `/.well-known/oauth-protected-resource` (also under the endpoint's
  path) and `/.well-known/oauth-authorization-server`. Mount at the root:

      forward "/.well-known", Sake.Auth.WellKnown

  or `sake_well_known()` in a Phoenix router.
  """
  @behaviour Plug
  import Plug.Conn

  alias Sake.Auth.{Config, Resource}

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{method: "GET", path_info: ["oauth-protected-resource" | rest]} = conn, _opts),
    do: protected_resource(conn, rest)

  def call(
        %{method: "GET", path_info: [".well-known", "oauth-protected-resource" | rest]} = conn,
        _opts
      ),
      do: protected_resource(conn, rest)

  def call(%{method: "GET", path_info: ["oauth-authorization-server"]} = conn, _opts),
    do: authorization_server(conn)

  def call(
        %{method: "GET", path_info: [".well-known", "oauth-authorization-server"]} = conn,
        _opts
      ),
      do: authorization_server(conn)

  def call(conn, _opts), do: send_resp(conn, 404, "")

  defp protected_resource(conn, rest) do
    config = Sake.Auth.config()
    suffix = if rest == [], do: "", else: "/" <> Enum.join(rest, "/")

    json(conn, %{
      "resource" => Resource.origin(conn) <> suffix,
      "authorization_servers" => [config.issuer],
      "scopes_supported" => config |> Config.scopes() |> Enum.map(&elem(&1, 0)),
      "bearer_methods_supported" => ["header"],
      "resource_name" => config.name
    })
  end

  defp authorization_server(conn) do
    config = Sake.Auth.config()

    body = %{
      "issuer" => config.issuer,
      "authorization_endpoint" => Config.authorize_url(config),
      "token_endpoint" => Config.token_url(config),
      "revocation_endpoint" => Config.revoke_url(config),
      "scopes_supported" => config |> Config.scopes() |> Enum.map(&elem(&1, 0)),
      "response_types_supported" => ["code"],
      "grant_types_supported" => ["authorization_code", "refresh_token"],
      "code_challenge_methods_supported" => ["S256"],
      "token_endpoint_auth_methods_supported" => [
        "none",
        "client_secret_basic",
        "client_secret_post"
      ],
      "revocation_endpoint_auth_methods_supported" => [
        "none",
        "client_secret_basic",
        "client_secret_post"
      ],
      "client_id_metadata_document_supported" => config.cimd != false,
      "authorization_response_iss_parameter_supported" => true
    }

    body =
      if config.dcr,
        do: Map.put(body, "registration_endpoint", Config.register_url(config)),
        else: body

    json(conn, body)
  end

  defp json(conn, body) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "public, max-age=3600")
    |> send_resp(200, JSON.encode!(body))
  end
end
