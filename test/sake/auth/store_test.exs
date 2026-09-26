defmodule Sake.Auth.StoreTest do
  use SakeTest.AuthCase, async: false

  alias Sake.Auth.{Client, Code, Consent, Token, Tokens}

  defp store(config), do: {elem(config.store, 0), config.store_state}

  test "clients", %{config: config} do
    {mod, state} = store(config)

    client = %Client{
      id: "dc_1",
      name: "A",
      kind: :dynamic,
      redirect_uris: ["http://127.0.0.1:1/cb"],
      grant_types: ["authorization_code"],
      token_endpoint_auth_method: "none"
    }

    assert :ok = mod.put_client(state, client)
    assert {:ok, ^client} = mod.get_client(state, "dc_1")
    assert [^client] = mod.list_clients(state)
    assert :ok = mod.delete_client(state, "dc_1")
    assert :error = mod.get_client(state, "dc_1")
  end

  test "codes are consumed once", %{config: config} do
    {mod, state} = store(config)

    code = %Code{
      hash: Tokens.hash("c1"),
      client_id: "c",
      redirect_uri: "http://127.0.0.1:1/cb",
      code_challenge: "x",
      scopes: [],
      resource: "r",
      subject_id: "u",
      expires_at: DateTime.add(DateTime.utc_now(), 600)
    }

    assert :ok = mod.put_code(state, code)
    assert {:ok, ^code} = mod.consume_code(state, code.hash)
    assert :error = mod.consume_code(state, code.hash)
  end

  test "tokens, families and revocation", %{config: config} do
    {mod, state} = store(config)
    {_a, _r, %{access: a, refresh: r}} = issue(config, %{family_id: "f1", subject_id: "u1"})
    {_a2, _r2, %{access: a2}} = issue(config, %{family_id: "f2", subject_id: "u1"})
    assert :ok = mod.mark_used(state, r.id)
    assert {:ok, %Token{used_at: %DateTime{}}} = mod.get_token(state, :refresh, r.hash)
    assert :ok = mod.revoke_family(state, "f1")
    assert {:ok, %Token{revoked_at: %DateTime{}}} = mod.get_token(state, :access, a.hash)
    assert {:ok, %Token{revoked_at: nil}} = mod.get_token(state, :access, a2.hash)
    assert :ok = mod.revoke_token(state, a2.id)
    assert {:ok, %Token{revoked_at: %DateTime{}}} = mod.get_token(state, :access, a2.hash)
    assert length(mod.tokens_for_subject(state, "u1")) == 4
  end

  test "consents", %{config: config} do
    {mod, state} = store(config)

    consent = %Consent{
      subject_id: "u1",
      client_id: "c",
      scopes: ["a"],
      inserted_at: DateTime.utc_now()
    }

    assert :ok = mod.put_consent(state, consent)
    assert {:ok, %Consent{scopes: ["a"]}} = mod.get_consent(state, "u1", "c")
    assert :ok = mod.put_consent(state, %{consent | scopes: ["a", "b"]})
    assert {:ok, %Consent{scopes: ["a", "b"]}} = mod.get_consent(state, "u1", "c")
    assert :ok = mod.delete_consent(state, "u1", "c")
    assert :error = mod.get_consent(state, "u1", "c")
  end

  test "prune removes expired codes and tokens", %{config: config} do
    {mod, state} = store(config)
    past = DateTime.add(DateTime.utc_now(), -10)
    mod.put_code(state, %Code{hash: "old", expires_at: past})

    mod.put_token(state, %Token{
      id: "t-old",
      kind: :access,
      hash: "h-old",
      family_id: "f",
      subject_id: "u9",
      expires_at: past,
      inserted_at: past
    })

    {_, _, %{access: live}} = issue(config, %{subject_id: "u9"})
    assert :ok = mod.prune(state, DateTime.utc_now())
    assert :error = mod.consume_code(state, "old")
    assert :error = mod.get_token(state, :access, "h-old")
    assert {:ok, _} = mod.get_token(state, :access, live.hash)
  end
end
