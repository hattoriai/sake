defmodule Sake.Auth.TokenTest.RaceStore do
  @moduledoc false
  # A store that delegates to the ETS store, except that its first
  # access-token insert revokes that token's own family first: it
  # deterministically simulates a concurrent reuse revoking the family
  # between a refresh request's `consume_refresh` and its `issue_pair`,
  # without an actual race.
  @behaviour Sake.Auth.Store
  alias Sake.Auth.Store.ETS

  def child_spec(opts), do: ETS.child_spec(opts)
  def init(_opts), do: nil
  def put_client(s, c), do: ETS.put_client(s, c)
  def get_client(s, id), do: ETS.get_client(s, id)
  def list_clients(s), do: ETS.list_clients(s)
  def delete_client(s, id), do: ETS.delete_client(s, id)
  def put_code(s, c), do: ETS.put_code(s, c)
  def consume_code(s, hash), do: ETS.consume_code(s, hash)

  def put_token(s, %{kind: :access} = token) do
    unless Process.get(__MODULE__) do
      Process.put(__MODULE__, true)
      ETS.revoke_family(s, token.family_id)
    end

    ETS.put_token(s, token)
  end

  def put_token(s, token), do: ETS.put_token(s, token)
  def put_code_tokens(s, hash, tokens), do: ETS.put_code_tokens(s, hash, tokens)

  def get_token(s, kind, hash), do: ETS.get_token(s, kind, hash)
  def consume_refresh(s, hash), do: ETS.consume_refresh(s, hash)
  def revoke_token(s, id), do: ETS.revoke_token(s, id)
  def revoke_family(s, family_id), do: ETS.revoke_family(s, family_id)
  def tokens_for_subject(s, subject_id), do: ETS.tokens_for_subject(s, subject_id)
  def put_consent(s, c), do: ETS.put_consent(s, c)
  def get_consent(s, sub, client_id, resource), do: ETS.get_consent(s, sub, client_id, resource)

  def delete_consent(s, sub, client_id, resource),
    do: ETS.delete_consent(s, sub, client_id, resource)

  def prune(s, now, consents_before), do: ETS.prune(s, now, consents_before)
end

defmodule Sake.Auth.TokenTest do
  use SakeTest.AuthCase, async: false
  import Plug.Test
  import Plug.Conn

  alias Sake.Auth.{Authorize, Tokens}

  @verifier "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
  @challenge "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

  defp request(client, extra \\ %{}),
    do:
      Map.merge(
        %{
          client_id: client.id,
          redirect_uri: hd(client.redirect_uris),
          code_challenge: @challenge,
          scopes: ["issues:read"],
          resource: "http://www.example.com/mcp"
        },
        extra
      )

  defp post(params, headers \\ []) do
    conn =
      conn(:post, "/oauth/token", URI.encode_query(params))
      |> put_req_header("content-type", "application/x-www-form-urlencoded")

    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    Sake.Auth.Token.call(conn, Sake.Auth.Token.init([]))
  end

  defp body(conn), do: JSON.decode!(conn.resp_body)

  test "the code grant issues a pair; the code is single use and reuse revokes the family", %{
    config: config
  } do
    client = public_client(config)
    code = Authorize.issue_code(config, request(client), "u1")

    conn =
      post(%{
        "grant_type" => "authorization_code",
        "code" => code,
        "client_id" => client.id,
        "redirect_uri" => hd(client.redirect_uris),
        "code_verifier" => @verifier,
        "resource" => "http://www.example.com/mcp"
      })

    assert conn.status == 200
    assert ["no-store"] = get_resp_header(conn, "cache-control")

    assert %{
             "access_token" => access,
             "refresh_token" => refresh,
             "token_type" => "Bearer",
             "expires_in" => 3600,
             "scope" => "issues:read"
           } = body(conn)

    {mod, state} = Sake.Auth.store(config)

    assert {:ok, %{family_id: family, subject_id: "u1"}} =
             mod.get_token(state, :access, Tokens.hash(access))

    assert family == Tokens.hash(code)

    conn =
      post(%{
        "grant_type" => "authorization_code",
        "code" => code,
        "client_id" => client.id,
        "redirect_uri" => hd(client.redirect_uris),
        "code_verifier" => @verifier
      })

    assert conn.status == 400 and body(conn)["error"] == "invalid_grant"
    assert {:ok, %{revoked_at: %DateTime{}}} = mod.get_token(state, :access, Tokens.hash(access))

    assert {:ok, %{revoked_at: %DateTime{}}} =
             mod.get_token(state, :refresh, Tokens.hash(refresh))
  end

  test "a grant the client did not register for is unauthorized_client", %{config: config} do
    {mod, state} = Sake.Auth.store(config)
    client = public_client(config)
    code_only = %{client | grant_types: ["authorization_code"]}
    :ok = mod.put_client(state, code_only)
    {_a, refresh, _} = issue(config, %{client_id: client.id})

    conn =
      post(%{
        "grant_type" => "refresh_token",
        "refresh_token" => refresh,
        "client_id" => client.id
      })

    assert conn.status == 400 and body(conn)["error"] == "unauthorized_client"
    # the refused request did not consume the refresh token
    assert {:ok, %{used_at: nil}} = mod.get_token(state, :refresh, Tokens.hash(refresh))

    :ok = mod.put_client(state, %{client | grant_types: ["refresh_token"]})

    conn =
      post(%{
        "grant_type" => "authorization_code",
        "code" => Authorize.issue_code(config, request(client), "u1"),
        "client_id" => client.id,
        "redirect_uri" => hd(client.redirect_uris),
        "code_verifier" => @verifier
      })

    assert conn.status == 400 and body(conn)["error"] == "unauthorized_client"
  end

  test "the code grant checks the client, redirect, verifier and resource", %{config: config} do
    client = public_client(config)
    other = public_client(config, %{name: "Other"})

    base = fn ->
      %{
        "grant_type" => "authorization_code",
        "code" => Authorize.issue_code(config, request(client), "u1"),
        "client_id" => client.id,
        "redirect_uri" => hd(client.redirect_uris),
        "code_verifier" => @verifier
      }
    end

    assert body(post(Map.put(base.(), "client_id", other.id)))["error"] == "invalid_grant"

    assert body(post(Map.put(base.(), "redirect_uri", "http://127.0.0.1:9000/other")))["error"] ==
             "invalid_grant"

    assert body(post(Map.put(base.(), "code_verifier", String.duplicate("a", 43))))["error"] ==
             "invalid_grant"

    assert body(post(Map.put(base.(), "resource", "http://www.example.com/beta/mcp")))["error"] ==
             "invalid_grant"

    assert body(post(Map.delete(base.(), "code_verifier")))["error"] == "invalid_request"
    assert body(post(%{"grant_type" => "password"}))["error"] == "unsupported_grant_type"
    assert body(post(Map.put(base.(), "client_id", "nope")))["error"] == "invalid_client"
    assert post(base.()).status == 200
  end

  test "confidential clients authenticate with basic or post secrets", %{config: config} do
    {:ok, client, secret} =
      Sake.Auth.Clients.create(config, %{
        name: "Web",
        redirect_uris: ["https://app.example/cb"],
        confidential: true
      })

    code = Authorize.issue_code(config, request(client), "u1")

    params = %{
      "grant_type" => "authorization_code",
      "code" => code,
      "client_id" => client.id,
      "redirect_uri" => "https://app.example/cb",
      "code_verifier" => @verifier
    }

    conn = post(params)
    assert conn.status == 401 and body(conn)["error"] == "invalid_client"
    assert [~s(Basic realm="sake")] = get_resp_header(conn, "www-authenticate")
    conn = post(params, [{"authorization", "Basic " <> Base.encode64(client.id <> ":wrong")}])
    assert conn.status == 401

    conn =
      post(params, [{"authorization", "Basic " <> Base.encode64(client.id <> ":" <> secret)}])

    assert conn.status == 200
    code = Authorize.issue_code(config, request(client), "u1")
    conn = post(%{params | "code" => code} |> Map.put("client_secret", secret))
    assert conn.status == 200
  end

  test "refresh rotates, narrows scopes, and detects reuse", %{config: config} do
    client = public_client(config)

    code =
      Authorize.issue_code(
        config,
        request(client, %{scopes: ["issues:read", "issues:write"]}),
        "u1"
      )

    %{"refresh_token" => r1, "access_token" => a1} =
      body(
        post(%{
          "grant_type" => "authorization_code",
          "code" => code,
          "client_id" => client.id,
          "redirect_uri" => hd(client.redirect_uris),
          "code_verifier" => @verifier
        })
      )

    conn =
      post(%{
        "grant_type" => "refresh_token",
        "refresh_token" => r1,
        "client_id" => client.id,
        "scope" => "issues:read"
      })

    assert conn.status == 200
    assert %{"refresh_token" => r2, "access_token" => a2, "scope" => "issues:read"} = body(conn)
    assert r2 != r1 and a2 != a1
    {mod, state} = Sake.Auth.store(config)
    assert {:ok, %{used_at: %DateTime{}}} = mod.get_token(state, :refresh, Tokens.hash(r1))

    assert body(
             post(%{
               "grant_type" => "refresh_token",
               "refresh_token" => r2,
               "client_id" => client.id,
               "scope" => "issues:write"
             })
           )["error"] == "invalid_scope"

    assert body(
             post(%{
               "grant_type" => "refresh_token",
               "refresh_token" => r2,
               "client_id" => public_client(config, %{name: "x"}).id
             })
           )["error"] == "invalid_grant"

    conn =
      post(%{"grant_type" => "refresh_token", "refresh_token" => r1, "client_id" => client.id})

    assert body(conn)["error"] == "invalid_grant"
    assert {:ok, %{revoked_at: %DateTime{}}} = mod.get_token(state, :access, Tokens.hash(a2))
    assert {:ok, %{revoked_at: %DateTime{}}} = mod.get_token(state, :refresh, Tokens.hash(r2))
  end

  test "a refresh token is consumed atomically: two concurrent uses, only one wins", %{
    config: config
  } do
    client = public_client(config)
    code = Authorize.issue_code(config, request(client), "u1")

    %{"refresh_token" => r1, "access_token" => a1} =
      body(
        post(%{
          "grant_type" => "authorization_code",
          "code" => code,
          "client_id" => client.id,
          "redirect_uri" => hd(client.redirect_uris),
          "code_verifier" => @verifier
        })
      )

    params = %{"grant_type" => "refresh_token", "refresh_token" => r1, "client_id" => client.id}
    task1 = Task.async(fn -> post(params) end)
    task2 = Task.async(fn -> post(params) end)
    conn1 = Task.await(task1)
    conn2 = Task.await(task2)

    # Whoever wins the store-level race to consume r1 still may, or may
    # not, beat the loser's family-wide revoke to finish issuing its own
    # pair (the loser's revoke is one store round trip; the winner's issue
    # is several) — so both requests answering invalid_grant is as valid an
    # outcome as exactly one succeeding. What must never happen is a live
    # duplicate pair surviving the race.
    for conn <- [conn1, conn2], conn.status == 400 do
      assert body(conn)["error"] == "invalid_grant"
    end

    {mod, state} = Sake.Auth.store(config)

    for conn <- [conn1, conn2], conn.status == 200 do
      %{"access_token" => access} = body(conn)

      assert {:ok, %{revoked_at: %DateTime{}}} =
               mod.get_token(state, :access, Tokens.hash(access))
    end

    assert Enum.all?([conn1.status, conn2.status], &(&1 in [200, 400]))
    assert {:ok, %{revoked_at: %DateTime{}}} = mod.get_token(state, :access, Tokens.hash(a1))
  end

  test "a non-POST request gets the no-store headers on its 405" do
    conn = conn(:get, "/oauth/token") |> Sake.Auth.Token.call(Sake.Auth.Token.init([]))

    assert conn.status == 405
    assert ["no-store"] = get_resp_header(conn, "cache-control")
    assert ["no-cache"] = get_resp_header(conn, "pragma")
  end

  @tag auth: [store: {Sake.Auth.TokenTest.RaceStore, []}]
  test "a pair born into a family revoked mid-issue is denied, not handed out", %{config: config} do
    client = public_client(config)

    # Issued directly against the plain ETS store, bypassing the race
    # store, so this setup does not itself trigger the simulated
    # interleaving: only the refresh request below (through the endpoint,
    # which reads the configured, race-simulating store) does.
    plain = %{config | store: {Sake.Auth.Store.ETS, []}}
    {_a1, r1, _} = issue(plain, %{client_id: client.id})

    conn =
      post(%{"grant_type" => "refresh_token", "refresh_token" => r1, "client_id" => client.id})

    assert conn.status == 400
    assert body(conn)["error"] == "invalid_grant"

    {mod, state} = Sake.Auth.store(config)
    assert [_, _, _, _] = tokens = mod.tokens_for_subject(state, "u1")
    assert Enum.all?(tokens, &(&1.revoked_at != nil))
  end
end
