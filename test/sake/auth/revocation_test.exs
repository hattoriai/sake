defmodule Sake.Auth.RevocationTest do
  # Revocation, without HTTP.
  use SakeTest.AuthCase, async: false

  alias Sake.Auth.{Revocation, Tokens}

  test "revokes a token of the authenticated client, and forgets the consent", %{
    config: config
  } do
    client = public_client(config)
    {module, state} = Sake.Auth.store(config)
    {_access, refresh, _records} = issue(config, %{client_id: client.id})

    :ok =
      module.put_consent(state, %Sake.Auth.Consent{
        subject_id: "u1",
        client_id: client.id,
        resource: "http://www.example.com/mcp",
        scopes: [],
        inserted_at: DateTime.utc_now()
      })

    assert :ok = Revocation.revoke(config, %{"token" => refresh, "client_id" => client.id}, [])

    assert {:ok, %{revoked_at: %DateTime{}}} =
             module.get_token(state, :refresh, Tokens.hash(refresh))

    assert :error = module.get_consent(state, "u1", client.id, "http://www.example.com/mcp")
  end

  test "another client's token is left alone; no client at all is answered :ok", %{
    config: config
  } do
    client = public_client(config)
    {access, _, _} = issue(config, %{client_id: "someone-else"})
    {module, state} = Sake.Auth.store(config)

    assert :ok =
             Revocation.revoke(
               config,
               %{
                 "token" => access,
                 "token_type_hint" => "access_token",
                 "client_id" => client.id
               },
               []
             )

    assert {:ok, %{revoked_at: nil}} = module.get_token(state, :access, Tokens.hash(access))
    assert :ok = Revocation.revoke(config, %{"token" => access}, [])

    assert {:error, 401, "invalid_client", _} =
             Revocation.revoke(config, %{"token" => access, "client_id" => "nope"}, [])

    assert {:error, 401, "invalid_client", _} =
             Revocation.revoke(config, %{"token" => access}, ["Basic " <> Base.encode64("a:b")])
  end
end
