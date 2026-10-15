defmodule Sake.Client.Auth.GrantTest do
  use ExUnit.Case, async: true
  alias Sake.Client.Auth.Grant

  @server %{
    resource: "https://mcp.example.com/mcp",
    issuer: "https://auth.example.com",
    metadata: %{"authorization_endpoint" => "https://auth.example.com/authorize?tenant=a"}
  }

  test "S256 of the RFC 7636 example verifier" do
    assert Grant.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") ==
             "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
  end

  test "a fresh verifier per request, 43 characters of the unreserved set" do
    {v1, c1} = Grant.pkce()
    {v2, _} = Grant.pkce()

    assert byte_size(v1) == 43 and v1 =~ ~r/^[A-Za-z0-9_-]+$/
    assert v1 != v2 and c1 == Grant.challenge(v1)
  end

  test "the authorization URL keeps the endpoint's own query and carries every parameter" do
    {url, request} =
      Grant.request(@server, %{"client_id" => "c"}, "http://127.0.0.1:1/cb", ["a", "b"])

    uri = URI.parse(url)
    params = URI.decode_query(uri.query)

    assert "#{uri.scheme}://#{uri.host}#{uri.path}" == "https://auth.example.com/authorize"

    assert %{
             "tenant" => "a",
             "response_type" => "code",
             "client_id" => "c",
             "redirect_uri" => "http://127.0.0.1:1/cb",
             "code_challenge_method" => "S256",
             "resource" => "https://mcp.example.com/mcp",
             "scope" => "a b"
           } = params

    assert params["state"] == request.state
    assert params["code_challenge"] == Grant.challenge(request.verifier)
    assert request.issuer == "https://auth.example.com" and request.iss_required == false
    assert uri.query =~ "scope=a%20b"
  end

  describe "the authorization response (RFC 9207 §2.4)" do
    setup do
      {_url, request} = Grant.request(@server, %{"client_id" => "c"}, "http://127.0.0.1:1/cb", [])
      %{request: request, required: %{request | iss_required: true}}
    end

    test "advertised and present: compared", %{required: r} do
      assert {:ok, "x"} =
               Grant.callback(%{"code" => "x", "state" => r.state, "iss" => r.issuer}, r)

      assert {:error, {:issuer_mismatch, _, "https://evil.example.com"}} =
               Grant.callback(
                 %{"code" => "x", "state" => r.state, "iss" => "https://evil.example.com"},
                 r
               )
    end

    test "advertised and absent: refused", %{required: r} do
      assert {:error, :missing_iss} = Grant.callback(%{"code" => "x", "state" => r.state}, r)
    end

    test "not advertised and present: compared all the same", %{request: r} do
      assert {:error, {:issuer_mismatch, _, _}} =
               Grant.callback(
                 %{"code" => "x", "state" => r.state, "iss" => "https://evil.example.com"},
                 r
               )
    end

    test "not advertised and absent: accepted", %{request: r} do
      assert {:ok, "x"} = Grant.callback(%{"code" => "x", "state" => r.state}, r)
    end

    test "compared as strings, without normalization", %{request: r} do
      for iss <- [
            "https://auth.example.com/",
            "HTTPS://auth.example.com",
            "https://auth.example.com:443"
          ] do
        assert {:error, {:issuer_mismatch, _, ^iss}} =
                 Grant.callback(%{"code" => "x", "state" => r.state, "iss" => iss}, r)
      end
    end

    test "an error from the wrong server is not reported", %{request: r} do
      params = %{
        "error" => "access_denied",
        "state" => r.state,
        "iss" => "https://evil.example.com"
      }

      assert {:error, {:issuer_mismatch, _, _}} = Grant.callback(params, r)
    end

    test "the state must be the request's", %{request: r} do
      assert {:error, :state_mismatch} = Grant.callback(%{"code" => "x", "state" => "other"}, r)
      assert {:error, :state_mismatch} = Grant.callback(%{"code" => "x"}, r)
    end

    test "an error, then a missing code", %{request: r} do
      assert {:error, {:denied, "access_denied", "No"}} =
               Grant.callback(
                 %{"error" => "access_denied", "error_description" => "No", "state" => r.state},
                 r
               )

      assert {:error, :no_code} = Grant.callback(%{"state" => r.state}, r)
    end
  end
end
