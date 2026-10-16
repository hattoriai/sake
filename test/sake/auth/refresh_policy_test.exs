defmodule Sake.Auth.RefreshPolicyTest.Subject do
  @moduledoc false
  # The development subject, with a policy the test changes as it goes: the
  # resources a person was removed from, and the accounts disabled.
  @behaviour Sake.Auth.Subject

  def remove(resource), do: Process.put(:removed, [resource | Process.get(:removed, [])])
  def disable(id), do: Process.put(:disabled, [id | Process.get(:disabled, [])])

  @impl true
  defdelegate from_conn(conn), to: SakeDev.Subject
  @impl true
  defdelegate id(person), to: SakeDev.Subject
  @impl true
  defdelegate display(person), to: SakeDev.Subject

  @impl true
  def fetch(id),
    do: if(id in Process.get(:disabled, []), do: :error, else: SakeDev.Subject.fetch(id))

  @impl true
  def authorize_resource?(_person, resource), do: resource not in Process.get(:removed, [])
end

defmodule Sake.Auth.RefreshPolicyTest do
  # A refresh renews a grant only while the person may still have it
  # (issue #32).
  use SakeTest.AuthCase, async: false
  @moduletag auth: [subject: Sake.Auth.RefreshPolicyTest.Subject]

  import Plug.Test
  import Plug.Conn

  alias Sake.Auth.RefreshPolicyTest.Subject
  alias Sake.Auth.Tokens

  @acme "http://www.example.com/acme/mcp"
  @beta "http://www.example.com/beta/mcp"

  defp refresh(client, refresh, extra \\ %{}) do
    params =
      Map.merge(
        %{"grant_type" => "refresh_token", "refresh_token" => refresh, "client_id" => client.id},
        extra
      )

    conn(:post, "/oauth/token", URI.encode_query(params))
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> Sake.Auth.Token.call(Sake.Auth.Token.init([]))
  end

  defp body(conn), do: JSON.decode!(conn.resp_body)

  defp grant(config, client, resource, scopes \\ ["issues:read"]) do
    {access, refresh, _} =
      issue(config, %{
        client_id: client.id,
        subject_id: "u1",
        resource: resource,
        scopes: scopes,
        family_id: Tokens.hash(resource <> client.id)
      })

    {access, refresh}
  end

  defp valid?(config, kind, token) do
    {mod, state} = Sake.Auth.store(config)
    {:ok, record} = mod.get_token(state, kind, Tokens.hash(token))
    Tokens.valid?(record, DateTime.utc_now())
  end

  test "a person still authorized for the resource renews the grant", %{config: config} do
    client = public_client(config)
    {_access, r1} = grant(config, client, @acme)

    conn = refresh(client, r1)
    assert conn.status == 200
    assert %{"refresh_token" => r2, "scope" => "issues:read"} = body(conn)
    assert refresh(client, r2).status == 200
  end

  test "a person removed from the resource cannot renew, and the grant is revoked", %{
    config: config
  } do
    client = public_client(config)
    {access, r1} = grant(config, client, @acme)
    {_beta_access, beta_refresh} = grant(config, client, @beta)

    Subject.remove(@acme)

    conn = refresh(client, r1)
    assert conn.status == 400

    assert %{
             "error" => "invalid_grant",
             "error_description" => "The grant is no longer authorized"
           } =
             body(conn)

    refute valid?(config, :access, access)
    refute valid?(config, :refresh, r1)

    # Another membership is unaffected.
    assert refresh(client, beta_refresh).status == 200
  end

  test "a disabled account cannot renew, and the grant is revoked", %{config: config} do
    client = public_client(config)
    {access, r1} = grant(config, client, @acme)

    Subject.disable("u1")

    conn = refresh(client, r1)
    assert conn.status == 400 and body(conn)["error"] == "invalid_grant"
    refute valid?(config, :access, access)
  end

  test "an explicitly revoked grant cannot renew", %{config: config} do
    client = public_client(config)
    {_access, r1} = grant(config, client, @acme)

    :ok = Sake.Auth.revoke_grant(config, "u1", client.id)

    assert %{"error" => "invalid_grant"} = body(refresh(client, r1))
  end

  test "a client whose allowed scopes were narrowed renews with only those", %{config: config} do
    client = public_client(config)
    {_access, r1} = grant(config, client, @acme, ["issues:read", "issues:write"])

    {mod, state} = Sake.Auth.store(config)
    :ok = mod.put_client(state, %{client | scopes: ["issues:read"]})

    conn = refresh(client, r1)
    assert conn.status == 200
    assert %{"access_token" => access, "scope" => "issues:read"} = body(conn)
    {:ok, record} = mod.get_token(state, :access, Tokens.hash(access))
    assert record.scopes == ["issues:read"]
  end
end
