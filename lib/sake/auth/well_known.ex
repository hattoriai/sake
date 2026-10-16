defmodule Sake.Auth.WellKnown do
  @moduledoc """
  Serves `/.well-known/oauth-protected-resource` (also under the endpoint's
  path) and `/.well-known/oauth-authorization-server`. Mount at the root:

      forward "/.well-known", Sake.Auth.WellKnown

  or `sake_well_known()` in a Phoenix router.
  """
  @behaviour Plug
  import Plug.Conn

  alias Sake.Auth.{Config, DPoP, JWT, Resource}

  @id_jag_profile "urn:ietf:params:oauth:grant-profile:id-jag"

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

    json(
      conn,
      dpop_algs(config, %{
        "resource" => Resource.origin(conn) <> suffix,
        "authorization_servers" => [config.issuer],
        "scopes_supported" => config |> Config.scopes() |> Enum.map(&elem(&1, 0)),
        "bearer_methods_supported" => ["header"],
        "resource_name" => config.name
      })
    )
  end

  # RFC 9449 §5.1 (the authorization server) and RFC 9728 §2 (the
  # resource): the algorithms DPoP proofs may use, which is how a client
  # learns that DPoP is on offer at all.
  defp dpop_algs(%Config{dpop: false}, body), do: body

  defp dpop_algs(_config, body),
    do: Map.put(body, "dpop_signing_alg_values_supported", DPoP.algs())

  defp authorization_server(conn) do
    config = Sake.Auth.config()

    body = %{
      "issuer" => config.issuer,
      "authorization_endpoint" => Config.authorize_url(config),
      "token_endpoint" => Config.token_url(config),
      "revocation_endpoint" => Config.revoke_url(config),
      "scopes_supported" => config |> Config.scopes() |> Enum.map(&elem(&1, 0)),
      "response_types_supported" => ["code"],
      "grant_types_supported" => Sake.Auth.Token.grant_types(config),
      "code_challenge_methods_supported" => ["S256"],
      "token_endpoint_auth_methods_supported" => auth_methods(),
      "revocation_endpoint_auth_methods_supported" => auth_methods(),
      "client_id_metadata_document_supported" => config.cimd != false,
      "authorization_response_iss_parameter_supported" => true
    }

    body =
      if JWT.available?(),
        do:
          body
          |> Map.put("token_endpoint_auth_signing_alg_values_supported", JWT.algs())
          |> Map.put("revocation_endpoint_auth_signing_alg_values_supported", JWT.algs()),
        else: body

    # draft-ietf-oauth-identity-assertion-authz-grant §7.2: how a client
    # learns that ID-JAGs are accepted here.
    body =
      if Enum.any?(config.trusted_issuers, &(&1.profile == :id_jag)),
        do: Map.put(body, "authorization_grant_profiles_supported", [@id_jag_profile]),
        else: body

    body =
      if config.dcr,
        do: Map.put(body, "registration_endpoint", Config.register_url(config)),
        else: body

    json(conn, dpop_algs(config, body))
  end

  # `private_key_jwt` needs jose to verify the client's assertion.
  defp auth_methods do
    ["none", "client_secret_basic", "client_secret_post"] ++
      if JWT.available?(), do: ["private_key_jwt"], else: []
  end

  defp json(conn, body) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "public, max-age=3600")
    |> send_resp(200, JSON.encode!(body))
  end
end
