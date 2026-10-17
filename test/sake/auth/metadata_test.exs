defmodule Sake.Auth.MetadataTest do
  # The metadata documents, without HTTP: each feature's fields come from
  # its contributor, and go when the feature is off.
  use SakeTest.AuthCase, async: false

  alias Sake.Auth.{External, Metadata}

  @resource "http://www.example.com/mcp"

  test "the authorization server metadata", %{config: config} do
    m = Metadata.authorization_server(config)

    assert m["issuer"] == "http://www.example.com"
    assert m["authorization_endpoint"] == "http://www.example.com/oauth/authorize"
    assert m["token_endpoint"] == "http://www.example.com/oauth/token"
    assert m["revocation_endpoint"] == "http://www.example.com/oauth/revoke"
    assert m["registration_endpoint"] == "http://www.example.com/oauth/register"
    assert m["response_types_supported"] == ["code"]
    assert m["code_challenge_methods_supported"] == ["S256"]
    assert m["authorization_response_iss_parameter_supported"] == true
    assert m["client_id_metadata_document_supported"] == true
    assert "private_key_jwt" in m["token_endpoint_auth_methods_supported"]
    assert m["token_endpoint_auth_signing_alg_values_supported"] == Sake.Auth.JWT.algs()
    assert m["dpop_signing_alg_values_supported"] == Sake.Auth.DPoP.algs()

    assert m["grant_types_supported"] == [
             "authorization_code",
             "refresh_token",
             "client_credentials"
           ]

    refute Map.has_key?(m, "authorization_grant_profiles_supported")
  end

  test "a feature that is off contributes nothing", %{config: config} do
    m = Metadata.authorization_server(%{config | dcr: false, dpop: false, cimd: false})

    refute Map.has_key?(m, "registration_endpoint")
    refute Map.has_key?(m, "dpop_signing_alg_values_supported")
    assert m["client_id_metadata_document_supported"] == false
  end

  test "trusting an ID-JAG issuer adds its grant profile", %{config: config} do
    config = %{config | trusted_issuers: [%{profile: :id_jag}]}

    assert Metadata.authorization_server(config)["authorization_grant_profiles_supported"] == [
             "urn:ietf:params:oauth:grant-profile:id-jag"
           ]
  end

  test "the protected resource metadata", %{config: config} do
    assert %{
             "resource" => @resource,
             "authorization_servers" => ["http://www.example.com"],
             "bearer_methods_supported" => ["header"],
             "resource_name" => "www.example.com",
             "dpop_signing_alg_values_supported" => _
           } = m = Metadata.protected_resource(config, @resource)

    assert "issues:read" in m["scopes_supported"]
    refute Map.has_key?(m, "dpop_bound_access_tokens_required")

    m = Metadata.protected_resource(%{config | dpop: %{nonce: false, required: true}}, @resource)
    assert m["dpop_bound_access_tokens_required"] == true

    m = Metadata.protected_resource(%{config | dpop: false}, @resource)
    refute Map.has_key?(m, "dpop_signing_alg_values_supported")
  end

  test "an external server's protected resource metadata names it" do
    external = %External{issuer: "https://sso.example", dpop: false, servers: [SakeDev.Server]}
    m = Metadata.protected_resource(external, @resource)

    assert m["authorization_servers"] == ["https://sso.example"]
    refute Map.has_key?(m, "resource_name")
  end
end
