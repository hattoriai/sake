defmodule Sake.Auth.TokensTest do
  use SakeTest.AuthCase, async: false

  alias Sake.Auth.{PKCE, Tokens}

  test "generate and hash" do
    t = Tokens.generate()
    assert byte_size(t) == 43 and Regex.match?(~r/^[A-Za-z0-9_-]+$/, t)
    assert Tokens.hash(t) == :crypto.hash(:sha256, t) |> Base.encode16(case: :lower)
    assert Tokens.generate() != t
  end

  test "issue_pair stores hashed access and refresh tokens with TTLs", %{config: config} do
    {access, refresh, %{access: a, refresh: r}} = issue(config, %{scopes: ["issues:read"]})
    assert a.kind == :access and r.kind == :refresh
    assert a.hash == Tokens.hash(access) and r.hash == Tokens.hash(refresh)
    assert a.family_id == r.family_id
    assert DateTime.diff(a.expires_at, DateTime.utc_now()) in 3_590..3_600
    assert DateTime.diff(r.expires_at, DateTime.utc_now()) in (30 * 86_400 - 10)..(30 * 86_400)
    {mod, state} = {elem(config.store, 0), config.store_state}
    assert {:ok, %{scopes: ["issues:read"]}} = mod.get_token(state, :access, a.hash)
    assert {:ok, _} = mod.get_token(state, :refresh, r.hash)
    assert :error = mod.get_token(state, :access, r.hash)
  end

  test "PKCE S256" do
    verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    assert PKCE.verify("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", verifier)
    refute PKCE.verify("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cX", verifier)
    refute PKCE.verify(nil, verifier)
    refute PKCE.verify("x", "short")
  end
end
