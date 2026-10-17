defmodule Sake.Auth.AuthenticationTest do
  # How the person signed in (RFC 9470), without HTTP: the context, the
  # requirements, an authorization request's `acr_values` and `max_age`,
  # the metadata and the challenge.
  use SakeTest.AuthCase, async: false

  alias Sake.Auth.{Authentication, AuthorizationRequest, Bearer, Challenge, Metadata}

  @challenge "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
  @resource "http://www.example.com/mcp"
  @now ~U[2026-10-17 12:00:00Z]

  defp ago(seconds), do: DateTime.add(@now, -seconds)

  defp params(client, extra) do
    Map.merge(
      %{
        "response_type" => "code",
        "client_id" => client.id,
        "redirect_uri" => hd(client.redirect_uris),
        "code_challenge" => @challenge,
        "code_challenge_method" => "S256",
        "resource" => @resource
      },
      extra
    )
  end

  describe "check/3" do
    test "the acr must be one of those asked for, a missing one meets none" do
      mfa = %{acr_values: ["mfa", "hwk"], max_age: nil}

      assert :ok = Authentication.check(%{acr: "mfa", auth_time: nil}, mfa, @now)
      assert :ok = Authentication.check(%{acr: "hwk", auth_time: nil}, mfa, @now)
      assert {:error, :acr} = Authentication.check(%{acr: "pwd", auth_time: nil}, mfa, @now)
      assert {:error, :acr} = Authentication.check(Authentication.none(), mfa, @now)
    end

    test "the sign-in must be no older than max_age, a missing time meets none" do
      recent = %{acr_values: [], max_age: 300}

      assert :ok = Authentication.check(%{acr: nil, auth_time: ago(300)}, recent, @now)

      assert {:error, :max_age} =
               Authentication.check(%{acr: nil, auth_time: ago(301)}, recent, @now)

      assert {:error, :max_age} = Authentication.check(Authentication.none(), recent, @now)

      # A clock a little ahead of ours is no older than now.
      assert :ok = Authentication.check(%{acr: nil, auth_time: ago(-5)}, recent, @now)
    end

    test "max_age 0 is a sign-in within the last minute" do
      fresh = %{acr_values: [], max_age: 0}

      assert :ok = Authentication.check(%{acr: nil, auth_time: ago(60)}, fresh, @now)

      assert {:error, :max_age} =
               Authentication.check(%{acr: nil, auth_time: ago(61)}, fresh, @now)
    end

    test "both parts, the acr first; nil asks for nothing" do
      both = %{acr_values: ["mfa"], max_age: 300}

      assert :ok = Authentication.check(%{acr: "mfa", auth_time: ago(10)}, both, @now)
      assert {:error, :acr} = Authentication.check(%{acr: "pwd", auth_time: ago(900)}, both, @now)

      assert {:error, :max_age} =
               Authentication.check(%{acr: "mfa", auth_time: ago(900)}, both, @now)

      assert :ok = Authentication.check(Authentication.none(), nil, @now)
    end
  end

  test "context/1 normalizes what a host or a record gives" do
    at = ~U[2026-10-17 11:00:00.123456Z]

    assert %{acr: "mfa", auth_time: ~U[2026-10-17 11:00:00Z]} =
             Authentication.context(%{acr: "mfa", auth_time: at})

    assert %{acr: nil, auth_time: ~U[2026-10-17 11:00:00Z]} =
             Authentication.context(%{acr: "", auth_time: DateTime.to_unix(at)})

    assert %{acr: nil, auth_time: nil} = Authentication.context(%{acr: :mfa, auth_time: "now"})
    assert %{acr: nil, auth_time: nil} = Authentication.context(:error)
  end

  describe "requirement!/2 and merge!/3" do
    test "a declaration" do
      assert %{acr_values: ["mfa"], max_age: 300} =
               Authentication.requirement!([acr: "mfa", max_age: 300], "T")

      assert %{acr_values: ["mfa", "hwk"], max_age: nil} =
               Authentication.requirement!([acr: ["mfa", "hwk"]], "T")

      assert %{acr_values: [], max_age: 0} = Authentication.requirement!([max_age: 0], "T")
      assert nil == Authentication.requirement!(nil, "T")

      for bad <- [[acr: 1], [max_age: -1], [max_age: "300"], [mfa: true], "mfa", [acr: [""]]] do
        assert_raise ArgumentError, ~r/T: authentication: takes/, fn ->
          Authentication.requirement!(bad, "T")
        end
      end
    end

    test "two requirements: an acr of both lists, and the shorter max_age" do
      server = %{acr_values: ["mfa", "hwk"], max_age: 600}

      assert %{acr_values: ["hwk"], max_age: 300} =
               Authentication.merge!(%{acr_values: ["hwk"], max_age: 300}, server, "T")

      assert %{acr_values: ["mfa", "hwk"], max_age: 600} =
               Authentication.merge!(%{acr_values: [], max_age: nil}, server, "T")

      assert ^server = Authentication.merge!(nil, server, "T")

      assert_raise ArgumentError, ~r/has none of the server's/, fn ->
        Authentication.merge!(%{acr_values: ["pwd"], max_age: nil}, server, "T")
      end

      # At runtime, the component's own list is kept.
      assert %{acr_values: ["pwd"]} =
               Authentication.merge(%{acr_values: ["pwd"], max_age: nil}, server)
    end
  end

  describe "an authorization request's acr_values and max_age" do
    test "go in extra, on every flow", %{config: config} do
      client = public_client(config)

      assert {:ok, %AuthorizationRequest{extra: extra}} =
               AuthorizationRequest.validate(
                 config,
                 client,
                 params(client, %{"acr_values" => "mfa  hwk mfa", "max_age" => "300"})
               )

      assert extra == %{"acr_values" => ["mfa", "hwk"], "max_age" => 300}
      assert Authentication.requested(extra) == %{acr_values: ["mfa", "hwk"], max_age: 300}

      device =
        public_client(config, %{
          redirect_uris: [],
          grant_types: ["urn:ietf:params:oauth:grant-type:device_code"]
        })

      assert {:ok, %AuthorizationRequest{extra: %{"max_age" => 0}}} =
               AuthorizationRequest.validate(
                 config,
                 device,
                 %{"resource" => @resource, "max_age" => "0"},
                 :device
               )
    end

    test "none asked, nothing in extra", %{config: config} do
      client = public_client(config)

      assert {:ok, %AuthorizationRequest{extra: extra}} =
               AuthorizationRequest.validate(
                 config,
                 client,
                 params(client, %{"acr_values" => ""})
               )

      assert extra == %{}
      assert Authentication.requested(extra) == nil
    end

    test "a max_age that is not a non-negative integer is refused", %{config: config} do
      client = public_client(config)

      for bad <- ["-1", "5m", "", "1.5"] do
        assert {:error, "invalid_request", "max_age must be a non-negative integer"} =
                 AuthorizationRequest.validate(
                   config,
                   client,
                   params(client, %{"max_age" => bad})
                 ),
               bad
      end
    end

    @tag auth: [acr_values: ["pwd", "mfa"]]
    test "with acr_values: configured, unknown values are dropped, and none left is refused", %{
      config: config
    } do
      client = public_client(config)

      assert {:ok, %AuthorizationRequest{extra: %{"acr_values" => ["mfa"]}}} =
               AuthorizationRequest.validate(
                 config,
                 client,
                 params(client, %{"acr_values" => "urn:x:loa:4 mfa"})
               )

      assert {:error, "invalid_request", "None of the acr_values is supported: urn:x:loa:4"} =
               AuthorizationRequest.validate(
                 config,
                 client,
                 params(client, %{"acr_values" => "urn:x:loa:4"})
               )
    end
  end

  describe "metadata" do
    @tag auth: [acr_values: ["pwd", "mfa"]]
    test "acr_values_supported, from acr_values:", %{config: config} do
      assert Metadata.authorization_server(config)["acr_values_supported"] == ["pwd", "mfa"]
    end

    test "nothing without acr_values:", %{config: config} do
      refute Map.has_key?(Metadata.authorization_server(config), "acr_values_supported")
    end

    test "acr_values: must be a list of strings" do
      for bad <- [[], "mfa", ["two words"], [:mfa]] do
        assert_raise ArgumentError, ~r/acr_values: must be/, fn ->
          Sake.Auth.Config.new(
            subject: SakeDev.Subject,
            issuer: "https://a.example",
            acr_values: bad
          )
        end
      end
    end
  end

  describe "the challenge" do
    test "is RFC 9470's, in the token's scheme, and parses back" do
      url = "http://www.example.com/mcp"
      metadata = "http://www.example.com/.well-known/oauth-protected-resource/mcp"

      challenge =
        Bearer.insufficient_user_authentication(
          url,
          %{acr_values: ["mfa"], max_age: 300},
          :acr,
          [],
          false
        )

      assert %Challenge{status: 401, scheme: "Bearer", www_authenticate: [header]} = challenge

      assert header ==
               ~s(Bearer error="insufficient_user_authentication", error_description="A different authentication level is required", acr_values="mfa", max_age="300", resource_metadata="#{metadata}")

      assert %Challenge{
               error: "insufficient_user_authentication",
               acr_values: ["mfa"],
               max_age: 300,
               scope: []
             } = Challenge.parse(header)

      %Challenge{www_authenticate: [dpop]} =
        Bearer.insufficient_user_authentication(
          url,
          %{acr_values: [], max_age: 60},
          :max_age,
          ["issues:write"],
          true
        )

      assert dpop =~
               ~r/^DPoP error="insufficient_user_authentication", error_description="More recent authentication is required", max_age="60", scope="issues:write", resource_metadata="[^"]+", algs="[^"]+"$/

      assert %Challenge{acr_values: [], max_age: 60, scope: ["issues:write"]} =
               Challenge.parse(dpop)
    end
  end
end
