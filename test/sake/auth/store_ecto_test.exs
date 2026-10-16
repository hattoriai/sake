defmodule Sake.Auth.StoreEctoTest do
  use SakeTest.AuthCase, async: false
  @moduletag store: :ecto
  use SakeTest.StoreCases

  test "the migration is reversible" do
    opts = [all: true, log: false, migration_lock: false]
    Ecto.Migrator.run(SakeTest.Repo, [{0, SakeTest.Migration}], :down, opts)
    Ecto.Migrator.run(SakeTest.Repo, [{0, SakeTest.Migration}], :up, opts)
  end

  test "a code never consumed, or pruned, gets no tokens", %{config: config} do
    {mod, state} = store(config)
    hash = Tokens.hash("unknown")

    {_, _, %{access: a}} =
      Tokens.new_pair(config, %{
        family_id: hash,
        client_id: "c",
        subject_id: "u",
        scopes: [],
        resource: "r"
      })

    assert :revoked = mod.put_code_tokens(state, hash, [a])
    assert :error = mod.get_token(state, :access, a.hash)
  end

  test "put_token never resurrects a revoked or consumed token", %{config: config} do
    {mod, state} = store(config)

    {_a, _r, %{access: a, refresh: r}} =
      issue(config, %{family_id: "f-resurrect", subject_id: "u-resurrect"})

    assert :ok = mod.revoke_token(state, a.id)
    assert :ok = mod.put_token(state, a)
    assert {:ok, %TokenRecord{revoked_at: %DateTime{}}} = mod.get_token(state, :access, a.hash)

    assert {:ok, _} = mod.consume_refresh(state, r.hash)
    assert :ok = mod.put_token(state, r)
    assert {:ok, %TokenRecord{used_at: %DateTime{}}} = mod.get_token(state, :refresh, r.hash)
  end
end
