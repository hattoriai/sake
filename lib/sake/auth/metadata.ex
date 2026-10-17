defmodule Sake.Auth.Metadata do
  @moduledoc false
  # The metadata documents: the authorization server's (RFC 8414) and an
  # endpoint's protected resource metadata (RFC 9728).
  #
  # Each document is a base map and a list of contributors, small
  # functions of the configuration that return the fields of one feature
  # (DPoP, client ID metadata documents, dynamic registration, ID-JAGs,
  # the device grant, pushed authorization requests, the acr values, the
  # signing keys), or nothing when it is off. A feature adds its fields by
  # adding a contributor.
  #
  # With `openid:`, the OpenID Provider metadata (OpenID Connect
  # Discovery 1.0 §3) is the authorization server's, with the fields that
  # are OpenID Connect's alone added.
  #
  # Core: it takes the configuration and plain data, and never sees the
  # conn; `Sake.Auth.WellKnown` serves the documents.

  alias Sake.Auth.{Config, DPoP, External, JWT, SigningKeys, TokenGrants}

  @id_jag_profile "urn:ietf:params:oauth:grant-profile:id-jag"

  @doc "The authorization server metadata (RFC 8414) of Sake's own authorization server."
  @spec authorization_server(Config.t()) :: map()
  def authorization_server(config) do
    contribute(
      %{
        "issuer" => config.issuer,
        "authorization_endpoint" => Config.authorize_url(config),
        "token_endpoint" => Config.token_url(config),
        "revocation_endpoint" => Config.revoke_url(config),
        "scopes_supported" => request_scopes(config),
        "response_types_supported" => ["code"],
        "grant_types_supported" => TokenGrants.grant_types(config),
        "code_challenge_methods_supported" => ["S256"],
        "token_endpoint_auth_methods_supported" => auth_methods(),
        "revocation_endpoint_auth_methods_supported" => auth_methods(),
        "authorization_response_iss_parameter_supported" => true
      },
      config,
      [
        &cimd/1,
        &private_key_jwt/1,
        &id_jag/1,
        &dcr/1,
        &device/1,
        &par/1,
        &dpop_algs/1,
        &acr_values/1,
        &jwks/1
      ]
    )
  end

  # The claims an ID token or the userinfo endpoint may carry: the ID
  # token's own, and those of the `profile` and `email` scopes
  # (OpenID Connect Core §5.4), which `c:Sake.Auth.Subject.claims/2` may
  # return.
  @claims ~w(sub iss aud azp exp iat auth_time acr nonce at_hash
             name family_name given_name middle_name nickname preferred_username
             profile picture website gender birthdate zoneinfo locale updated_at
             email email_verified)

  @doc """
  The OpenID Provider metadata (OpenID Connect Discovery 1.0 §3), with
  `openid:`: the authorization server's, and the fields of OpenID
  Connect alone. nil without it.
  """
  @spec openid_configuration(Config.t()) :: map() | nil
  def openid_configuration(%Config{openid: false}), do: nil

  def openid_configuration(config) do
    Map.merge(authorization_server(config), %{
      "userinfo_endpoint" => Config.userinfo_url(config),
      "subject_types_supported" => ["public"],
      "id_token_signing_alg_values_supported" => SigningKeys.algs(config),
      "claims_supported" => @claims
    })
  end

  @doc """
  The protected resource metadata (RFC 9728) of the endpoint at
  `resource`, on Sake's own authorization server or an external one.
  """
  @spec protected_resource(Config.t() | External.t(), String.t()) :: map()
  def protected_resource(config, resource) do
    %{
      "resource" => resource,
      "authorization_servers" => [config.issuer],
      "scopes_supported" => scopes(config),
      "bearer_methods_supported" => ["header"],
      "resource_name" => resource_name(config)
    }
    |> Map.reject(fn {_k, v} -> v == nil end)
    |> contribute(config, [&dpop_algs/1, &dpop_required/1])
  end

  defp contribute(base, config, contributors),
    do: Enum.reduce(contributors, base, &Map.merge(&2, &1.(config)))

  defp scopes(config), do: config |> Config.scopes() |> Enum.map(&elem(&1, 0))
  defp request_scopes(config), do: config |> Config.request_scopes() |> Enum.map(&elem(&1, 0))

  defp resource_name(%Config{name: name}), do: name
  defp resource_name(%External{resource_name: name}), do: name

  # `private_key_jwt` needs jose to verify the client's assertion.
  defp auth_methods do
    ["none", "client_secret_basic", "client_secret_post"] ++
      if JWT.available?(), do: ["private_key_jwt"], else: []
  end

  # ---- contributors

  # draft-ietf-oauth-client-id-metadata-document: whether a client may
  # use the URL of its metadata document as its client_id.
  defp cimd(config), do: %{"client_id_metadata_document_supported" => config.cimd != false}

  defp private_key_jwt(_config) do
    if JWT.available?(),
      do: %{
        "token_endpoint_auth_signing_alg_values_supported" => JWT.algs(),
        "revocation_endpoint_auth_signing_alg_values_supported" => JWT.algs()
      },
      else: %{}
  end

  # draft-ietf-oauth-identity-assertion-authz-grant §7.2: how a client
  # learns that ID-JAGs are accepted here.
  defp id_jag(config) do
    if Enum.any?(config.trusted_issuers, &(&1.profile == :id_jag)),
      do: %{"authorization_grant_profiles_supported" => [@id_jag_profile]},
      else: %{}
  end

  defp dcr(config) do
    if config.dcr,
      do: %{"registration_endpoint" => Config.register_url(config)},
      else: %{}
  end

  # RFC 8628 §4: where a client starts the device authorization grant.
  defp device(%{device: false}), do: %{}

  defp device(config),
    do: %{"device_authorization_endpoint" => Config.device_authorization_url(config)}

  # RFC 9126 §5: where a client pushes its authorization requests, and
  # whether it must.
  defp par(%{par: false}), do: %{}

  defp par(config),
    do: %{
      "pushed_authorization_request_endpoint" => Config.par_url(config),
      "require_pushed_authorization_requests" => config.par.required
    }

  # RFC 9449 §5.1 (the authorization server) and RFC 9728 §2 (the
  # resource): the algorithms DPoP proofs may use, which is how a client
  # learns that DPoP is on offer at all.
  defp dpop_algs(%{dpop: false}), do: %{}
  defp dpop_algs(_config), do: %{"dpop_signing_alg_values_supported" => DPoP.algs()}

  # OpenID Connect Discovery's `acr_values_supported`, which RFC 9470
  # registers for an OAuth authorization server: the authentication
  # context classes the host's login offers, when it said.
  defp acr_values(%{acr_values: nil}), do: %{}
  defp acr_values(config), do: %{"acr_values_supported" => config.acr_values}

  # RFC 8414 §2: where the keys that sign the server's ID tokens are.
  defp jwks(%{openid: false}), do: %{}
  defp jwks(config), do: %{"jwks_uri" => Config.jwks_url(config)}

  # RFC 9728 §2: the resource takes DPoP-bound tokens only.
  defp dpop_required(config) do
    if Config.dpop_required?(config),
      do: %{"dpop_bound_access_tokens_required" => true},
      else: %{}
  end
end
