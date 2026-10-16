defmodule Sake.Auth.StoreTest do
  use SakeTest.AuthCase, async: false
  use SakeTest.StoreCases

  # A refresh stores its new pair while another request may be revoking
  # the family: the insert waits for a revocation in progress, so the
  # revocation's sweep never misses it while the endpoint's check (the
  # consumed refresh token not yet revoked) passes.
  test "put_token waits for a revocation in progress", %{config: config} do
    {mod, state} = store(config)
    {_, _, %{access: token}} = Sake.Auth.Tokens.new_pair(config, pair_attrs())

    :ok = :sys.suspend(Sake.Auth.Store.ETS)
    task = Task.async(fn -> mod.put_token(state, token) end)
    refute Task.yield(task, 100)
    assert :error = mod.get_token(state, :access, token.hash)

    :ok = :sys.resume(Sake.Auth.Store.ETS)
    assert :ok = Task.await(task)
    assert {:ok, _} = mod.get_token(state, :access, token.hash)
  end

  defp pair_attrs,
    do: %{family_id: "f-wait", client_id: "c", subject_id: "u", scopes: [], resource: "r"}
end
