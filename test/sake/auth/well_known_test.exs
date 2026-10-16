defmodule Sake.Auth.WellKnownTest do
  use SakeTest.AuthCase, async: false
  import Plug.Test

  defp get(path) do
    conn(:get, path) |> Sake.Auth.WellKnown.call(Sake.Auth.WellKnown.init([]))
  end

  test "protected resource metadata at the root and under a path" do
    conn = get("/.well-known/oauth-protected-resource")
    assert conn.status == 200
    assert ["application/json" <> _] = Plug.Conn.get_resp_header(conn, "content-type")
    assert ["public, max-age=3600"] = Plug.Conn.get_resp_header(conn, "cache-control")
    body = JSON.decode!(conn.resp_body)

    assert body == %{
             "resource" => "http://www.example.com",
             "authorization_servers" => ["http://www.example.com"],
             "scopes_supported" => ["issues:read", "issues:write"],
             "bearer_methods_supported" => ["header"],
             "resource_name" => "www.example.com",
             "dpop_signing_alg_values_supported" => ["RS256", "PS256", "ES256", "ES384"]
           }

    body = JSON.decode!(get("/.well-known/oauth-protected-resource/acme/mcp").resp_body)
    assert body["resource"] == "http://www.example.com/acme/mcp"
  end

  test "authorization server metadata" do
    body = JSON.decode!(get("/.well-known/oauth-authorization-server").resp_body)
    assert body["issuer"] == "http://www.example.com"
    assert body["authorization_endpoint"] == "http://www.example.com/oauth/authorize"
    assert body["token_endpoint"] == "http://www.example.com/oauth/token"
    assert body["registration_endpoint"] == "http://www.example.com/oauth/register"
    assert body["revocation_endpoint"] == "http://www.example.com/oauth/revoke"
    assert body["code_challenge_methods_supported"] == ["S256"]
    assert body["client_id_metadata_document_supported"] == true
    assert body["authorization_response_iss_parameter_supported"] == true

    assert body["grant_types_supported"] == [
             "authorization_code",
             "refresh_token",
             "client_credentials"
           ]

    assert body["response_types_supported"] == ["code"]

    assert body["token_endpoint_auth_methods_supported"] == [
             "none",
             "client_secret_basic",
             "client_secret_post",
             "private_key_jwt"
           ]

    assert body["token_endpoint_auth_signing_alg_values_supported"] ==
             ["RS256", "PS256", "ES256", "ES384"]

    refute Map.has_key?(body, "authorization_grant_profiles_supported")

    assert body["scopes_supported"] == ["issues:read", "issues:write"]

    assert body["dpop_signing_alg_values_supported"] == ["RS256", "PS256", "ES256", "ES384"]
  end

  @tag auth: [dpop: false]
  test "no DPoP algorithms when DPoP is off" do
    for path <- [
          "/.well-known/oauth-authorization-server",
          "/.well-known/oauth-protected-resource"
        ] do
      refute get(path).resp_body
             |> JSON.decode!()
             |> Map.has_key?("dpop_signing_alg_values_supported")
    end
  end

  @tag auth: [subject: SakeTest.TenantSubject]
  test "no client credentials grant without client_principal/1" do
    body = JSON.decode!(get("/.well-known/oauth-authorization-server").resp_body)
    assert body["grant_types_supported"] == ["authorization_code", "refresh_token"]
  end

  @tag auth: [dcr: false]
  test "no registration endpoint when DCR is off" do
    body = JSON.decode!(get("/.well-known/oauth-authorization-server").resp_body)
    refute Map.has_key?(body, "registration_endpoint")
  end

  test "other paths are 404" do
    assert get("/.well-known/other").status == 404
  end
end
