defmodule Sake.Auth.GrantsTest do
  use SakeTest.AuthCase, async: false

  test "list, revoke and prune", %{config: config} do
    client = public_client(config)
    issue(config, %{client_id: client.id, family_id: "f1", scopes: ["issues:read"]})
    issue(config, %{client_id: client.id, family_id: "f2", scopes: ["issues:read"]})
    issue(config, %{client_id: "other", family_id: "f3", subject_id: "u1"})
    issue(config, %{client_id: client.id, family_id: "f4", subject_id: "u2"})
    {mod, state} = Sake.Auth.store(config)

    mod.put_consent(state, %Sake.Auth.Consent{
      subject_id: "u1",
      client_id: client.id,
      scopes: ["issues:read"],
      inserted_at: DateTime.utc_now()
    })

    grants = Sake.Auth.list_grants(config, "u1")
    assert length(grants) == 2

    assert %{
             client_id: cid,
             client_name: "Test CLI",
             scopes: ["issues:read"],
             resource: "http://www.example.com/mcp",
             family_ids: ids,
             granted_at: %DateTime{}
           } = Enum.find(grants, &(&1.client_id == client.id))

    assert cid == client.id and Enum.sort(ids) == ["f1", "f2"]
    assert %{client_name: nil} = Enum.find(grants, &(&1.client_id == "other"))

    assert :ok = Sake.Auth.revoke_grant(config, "u1", client.id)
    assert [%{client_id: "other"}] = Sake.Auth.list_grants(config, "u1")
    assert :error = mod.get_consent(state, "u1", client.id)
    assert [%{client_id: _}] = Sake.Auth.list_grants(config, "u2")

    assert :ok = Sake.Auth.prune(config)
  end
end
