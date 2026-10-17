defmodule Sake.Auth.BearerCheckTest do
  # The access token check, without HTTP: the request is a map of its
  # headers, method and URL.
  use SakeTest.AuthCase, async: false

  alias Sake.Auth.{Bearer, Challenge, DPoP, JWT}

  @url "http://www.example.com/mcp"

  defp request(headers) do
    Map.merge(%{authorization: [], dpop: [], method: "POST", url: @url}, Map.new(headers))
  end

  test "a bearer token: its record, scopes and principal", %{config: config} do
    {access, _, _} = issue(config, %{scopes: ["issues:read"]})

    assert {:ok, %{token: token, scopes: ["issues:read"], principal: %{id: "u1"}} = accepted} =
             Bearer.check(config, request(authorization: ["Bearer " <> access]), @url, nil)

    assert token.subject_id == "u1"
    assert accepted.dpop == false and accepted.nonce == nil
  end

  test "a missing or unknown token: the 401 challenges", %{config: config} do
    for authorization <- [[], ["Bearer nope"], ["Basic x"], ["Bearer a", "Bearer b"]] do
      assert {:error, %Challenge{status: 401, scheme: "Bearer", error: nil} = challenge} =
               Bearer.check(config, request(authorization: authorization), @url, nil)

      assert challenge.resource_metadata ==
               "http://www.example.com/.well-known/oauth-protected-resource/mcp"

      assert [~s(Bearer resource_metadata=) <> _, ~s(DPoP resource_metadata=) <> _] =
               challenge.www_authenticate
    end

    # A token for another endpoint is not this one's.
    {access, _, _} = issue(config, %{resource: "http://www.example.com/acme/mcp"})

    assert {:error, %Challenge{status: 401}} =
             Bearer.check(config, request(authorization: ["Bearer " <> access]), @url, nil)
  end

  test "a DPoP-bound token needs a proof for this request", %{config: config} do
    {pem, jkt} = Sake.Auth.dpop_key()
    {:ok, key} = JWT.private_key(pem)
    {access, _, _} = issue(config, %{jkt: jkt})

    assert {:error, %Challenge{scheme: "DPoP", error: "invalid_token"}} =
             Bearer.check(config, request(authorization: ["Bearer " <> access]), @url, nil)

    assert {:error, %Challenge{scheme: "DPoP", error: "invalid_dpop_proof"}} =
             Bearer.check(config, request(authorization: ["DPoP " <> access]), @url, nil)

    proof = DPoP.proof(key, "POST", @url, access_token: access)

    assert {:ok, %{dpop: true}} =
             Bearer.check(
               config,
               request(authorization: ["DPoP " <> access], dpop: [proof]),
               @url,
               nil
             )

    # The proof names the method and the URL the request reached.
    proof = DPoP.proof(key, "POST", @url, access_token: access)

    assert {:error, %Challenge{error: "invalid_dpop_proof"}} =
             Bearer.check(
               config,
               request(authorization: ["DPoP " <> access], dpop: [proof], method: "GET"),
               @url,
               nil
             )
  end

  test "the 403 challenge names the scopes, in the token's scheme" do
    assert %Challenge{status: 403, scheme: "DPoP", www_authenticate: [header]} =
             Bearer.insufficient_scope(@url, ["issues:write"], true)

    assert header =~ ~s(DPoP error="insufficient_scope", scope="issues:write")

    assert %Challenge{scheme: "Bearer"} = Bearer.insufficient_scope(@url, ["x"], false)
  end
end
