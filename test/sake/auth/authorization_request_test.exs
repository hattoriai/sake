defmodule Sake.Auth.AuthorizationRequestTest do
  # The authorization request's rules, without HTTP: the parameters are a
  # plain map, as a pushed or device authorization request will give them.
  use SakeTest.AuthCase, async: false

  alias Sake.Auth.{AuthorizationRequest, Clients}

  @challenge "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
  @resource "http://www.example.com/mcp"

  defp params(client, extra \\ %{}) do
    Map.merge(
      %{
        "response_type" => "code",
        "client_id" => client.id,
        "redirect_uri" => hd(client.redirect_uris),
        "code_challenge" => @challenge,
        "code_challenge_method" => "S256",
        "state" => "xyz",
        "scope" => "issues:read",
        "resource" => @resource
      },
      extra
    )
  end

  describe "client/3" do
    test "the client, when the redirect URI is one it registered", %{config: config} do
      client = public_client(config)
      id = client.id

      assert {:ok, %{id: ^id}} =
               AuthorizationRequest.client(config, id, "http://127.0.0.1:9000/callback")

      assert {:error, :redirect_uri} =
               AuthorizationRequest.client(config, id, "http://evil.example/callback")

      assert {:error, :redirect_uri} = AuthorizationRequest.client(config, id, nil)
      assert {:error, :unknown_client} = AuthorizationRequest.client(config, "nope", "http://x")
      assert {:error, :unknown_client} = AuthorizationRequest.client(config, nil, "http://x")
    end
  end

  describe "validate/3" do
    test "a valid request becomes the struct, with no extra parameters yet", %{config: config} do
      client = public_client(config)

      assert {:ok, %AuthorizationRequest{} = request} =
               AuthorizationRequest.validate(config, client, params(client))

      assert request.client_id == client.id
      assert request.redirect_uri == "http://127.0.0.1:9000/callback"
      assert request.state == "xyz"
      assert request.code_challenge == @challenge
      assert request.scopes == ["issues:read"]
      assert request.resource == @resource
      assert request.extra == %{}
    end

    test "without scope, every scope the servers declare; without state, nil", %{config: config} do
      client = public_client(config)
      p = client |> params() |> Map.drop(["scope", "state"])
      assert {:ok, request} = AuthorizationRequest.validate(config, client, p)
      assert request.scopes == config |> Sake.Auth.Config.scopes() |> Enum.map(&elem(&1, 0))
      assert request.state == nil
    end

    test "each rule refuses with its error code", %{config: config} do
      client = public_client(config)

      for {extra, code, description} <- [
            {%{"response_type" => "token"}, "unsupported_response_type",
             "Only response_type=code is supported"},
            {%{"code_challenge" => ""}, "invalid_request", "code_challenge is required"},
            {%{"code_challenge" => nil}, "invalid_request", "code_challenge is required"},
            {%{"code_challenge_method" => "plain"}, "invalid_request",
             "code_challenge_method must be S256"},
            {%{"scope" => "issues:read nope"}, "invalid_scope", "Unknown scope: nope"},
            {%{"resource" => "https://other.example/mcp"}, "invalid_target",
             "The resource is not served by this authorization server"},
            {%{"resource" => "http://www.example.com/elsewhere"}, "invalid_target",
             "The resource is not served by this authorization server"}
          ] do
        p = client |> params(extra) |> Map.reject(fn {_, v} -> is_nil(v) end)

        assert AuthorizationRequest.validate(config, client, p) ==
                 {:error, code, description},
               inspect(extra)
      end
    end

    test "the client's own limits: its scopes and its grant types", %{config: config} do
      client = public_client(config, %{scopes: ["issues:read"]})

      assert {:error, "invalid_scope", "The client may not request: issues:write"} =
               AuthorizationRequest.validate(
                 config,
                 client,
                 params(client, %{"scope" => "issues:read issues:write"})
               )

      machine = %{client | grant_types: ["client_credentials"]}

      assert {:error, "unauthorized_client", _} =
               AuthorizationRequest.validate(config, machine, params(client))
    end

    test "a client resolved from its metadata is validated the same way", %{config: config} do
      {:ok, client} = Clients.resolve(config, public_client(config).id)
      assert {:ok, _request} = AuthorizationRequest.validate(config, client, params(client))
    end
  end

  describe "resource/2" do
    test "the parameter on the issuer's origin, under resources:", %{config: config} do
      assert AuthorizationRequest.resource(config, @resource) == {:ok, @resource}
      assert AuthorizationRequest.resource(config, @resource <> "/") == {:ok, @resource}

      assert AuthorizationRequest.resource(config, "http://www.example.com/acme/mcp") ==
               {:ok, "http://www.example.com/acme/mcp"}

      assert AuthorizationRequest.resource(config, "http://www.example.com/mcp?x=1") == :error
      assert AuthorizationRequest.resource(config, "https://www.example.com/mcp") == :error
      assert AuthorizationRequest.resource(config, 42) == :error
    end

    test "without the parameter, only a single fixed path", %{config: config} do
      assert AuthorizationRequest.resource(config, nil) == :error

      assert AuthorizationRequest.resource(%{config | resources: ["/mcp"]}, nil) ==
               {:ok, @resource}

      assert AuthorizationRequest.resource(%{config | resources: ["/:org/mcp"]}, nil) == :error
    end
  end
end
