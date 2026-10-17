defmodule Sake.Auth.ScopesForTest.Subject do
  @moduledoc false
  # The development subject, with roles: Ana (u1) is an admin and holds
  # every scope, Bo (u2) is a viewer and holds `issues:read` only, and a
  # machine client holds `issues:read`. The test changes a role as it goes.
  @behaviour Sake.Auth.Subject

  def role(id, role), do: Process.put({:role, id}, role)

  @impl true
  defdelegate from_conn(conn), to: SakeDev.Subject
  @impl true
  defdelegate id(person), to: SakeDev.Subject
  @impl true
  defdelegate fetch(id), to: SakeDev.Subject
  @impl true
  defdelegate display(person), to: SakeDev.Subject
  @impl true
  defdelegate client_principal(client), to: SakeDev.Subject

  @impl true
  def scopes_for(%{client: true}, _resource), do: ["issues:read"]

  def scopes_for(%{id: id}, _resource) do
    case Process.get({:role, id}, if(id == "u1", do: :admin, else: :viewer)) do
      :admin -> :all
      :viewer -> ["issues:read"]
      :none -> []
      :broken -> :oops
    end
  end
end

defmodule Sake.Auth.ScopesForTest do
  # `scopes_for/2` narrows every grant, and every request, to the scopes
  # the principal may hold.
  use SakeTest.AuthCase, async: false
  @moduletag auth: [subject: Sake.Auth.ScopesForTest.Subject]

  import Plug.Test
  import Plug.Conn

  alias Sake.Auth.{Authorize, Clients, Tokens}
  alias Sake.Auth.ScopesForTest.Subject
  alias SakeTest.ModernClient

  @challenge "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
  @resource "http://www.example.com/mcp"
  @both "issues:read issues:write"

  defp authorize(client, user, scope) do
    params = %{
      "response_type" => "code",
      "client_id" => client.id,
      "redirect_uri" => hd(client.redirect_uris),
      "code_challenge" => @challenge,
      "code_challenge_method" => "S256",
      "state" => "xyz",
      "scope" => scope,
      "resource" => @resource
    }

    conn(:get, "/oauth/authorize", params)
    |> init_test_session(%{user_id: user})
    |> Authorize.call(Authorize.init([]))
  end

  defp approve(conn, user) do
    [_, request] = Regex.run(~r/name="request" value="([^"]+)"/, conn.resp_body)

    conn(:post, "/oauth/authorize", %{"decision" => "approve", "request" => request})
    |> init_test_session(%{user_id: user})
    |> Authorize.call(Authorize.init([]))
  end

  defp code_scopes(config, conn) do
    [location] = get_resp_header(conn, "location")
    %{"code" => code} = URI.decode_query(URI.parse(location).query)
    {mod, state} = Sake.Auth.store(config)
    {:ok, %{scopes: scopes}} = mod.consume_code(state, Tokens.hash(code))
    scopes
  end

  defp redirect_query(conn) do
    [location] = get_resp_header(conn, "location")
    URI.decode_query(URI.parse(location).query)
  end

  defp token(params, headers \\ []) do
    conn =
      conn(:post, "/oauth/token", URI.encode_query(params))
      |> put_req_header("content-type", "application/x-www-form-urlencoded")

    headers
    |> Enum.reduce(conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    |> Sake.Auth.Token.call(Sake.Auth.Token.init([]))
  end

  defp body(conn), do: JSON.decode!(conn.resp_body)

  defp tool_names(access) do
    conn =
      ModernClient.post(ModernClient.opts(auth: true), "tools/list", %{},
        headers: [{"authorization", "Bearer " <> access}]
      )

    Enum.map(ModernClient.json(conn)["result"]["tools"], & &1["name"])
  end

  defp call_slow(access) do
    ModernClient.post(
      ModernClient.opts(auth: true),
      "tools/call",
      %{"name" => "slow", "arguments" => %{"n" => 1}},
      headers: [{"authorization", "Bearer " <> access}]
    )
  end

  describe "the authorize page" do
    test "an admin is granted every scope asked for", %{config: config} do
      client = public_client(config)
      conn = authorize(client, "u1", @both)
      assert conn.resp_body =~ "Read issues" and conn.resp_body =~ "Change issues"
      assert code_scopes(config, approve(conn, "u1")) == ["issues:read", "issues:write"]
    end

    test "a viewer is shown, and granted, only what they may hold", %{config: config} do
      client = public_client(config)
      conn = authorize(client, "u2", @both)
      assert conn.status == 200
      assert conn.resp_body =~ "Read issues"
      refute conn.resp_body =~ "Change issues"
      assert code_scopes(config, approve(conn, "u2")) == ["issues:read"]
    end

    test "a request with nothing the person may hold is refused", %{config: config} do
      client = public_client(config)

      assert %{
               "error" => "access_denied",
               "error_description" => "You may not hold any of the requested scopes",
               "state" => "xyz"
             } = redirect_query(authorize(client, "u2", "issues:write"))

      Subject.role("u2", :broken)
      assert %{"error" => "access_denied"} = redirect_query(authorize(client, "u2", @both))
    end

    test "a remembered consent covers the narrowed scopes", %{config: config} do
      client = public_client(config)
      approve(authorize(client, "u2", @both), "u2")
      assert authorize(client, "u2", @both).status == 302

      # Promoted, Bo is asked again for the scope now within reach.
      Subject.role("u2", :admin)
      assert authorize(client, "u2", @both).status == 200
    end
  end

  describe "grants without a person at the browser" do
    test "a machine client gets only what its principal may hold", %{config: config} do
      {:ok, client, secret} =
        Clients.create(config, %{
          name: "Nightly",
          grant_types: ["client_credentials"],
          confidential: true
        })

      params = %{
        "grant_type" => "client_credentials",
        "resource" => @resource,
        "client_id" => client.id,
        "client_secret" => secret
      }

      conn = token(params)
      assert conn.status == 200 and body(conn)["scope"] == "issues:read"

      conn = token(Map.put(params, "scope", "issues:write"))
      assert conn.status == 400 and body(conn)["error"] == "invalid_scope"
    end
  end

  describe "a refresh" do
    defp grant(config, client, scopes) do
      {_access, refresh, _} =
        issue(config, %{
          client_id: client.id,
          subject_id: "u2",
          scopes: scopes,
          resource: @resource,
          family_id: Tokens.hash("family" <> client.id)
        })

      refresh
    end

    defp refresh(client, refresh) do
      token(%{
        "grant_type" => "refresh_token",
        "refresh_token" => refresh,
        "client_id" => client.id
      })
    end

    test "renews with only the scopes the person may still hold", %{config: config} do
      client = public_client(config)
      Subject.role("u2", :admin)
      r1 = grant(config, client, ["issues:read", "issues:write"])

      Subject.role("u2", :viewer)
      conn = refresh(client, r1)
      assert conn.status == 200
      assert %{"scope" => "issues:read", "access_token" => access} = body(conn)
      {mod, state} = Sake.Auth.store(config)

      assert {:ok, %{scopes: ["issues:read"]}} =
               mod.get_token(state, :access, Tokens.hash(access))
    end

    test "with none left, is refused and revokes the grant", %{config: config} do
      client = public_client(config)
      r1 = grant(config, client, ["issues:read"])

      Subject.role("u2", :none)
      conn = refresh(client, r1)
      assert conn.status == 400

      assert %{
               "error" => "invalid_grant",
               "error_description" => "The grant is no longer authorized"
             } =
               body(conn)

      Subject.role("u2", :viewer)
      assert refresh(client, r1).status == 400
    end
  end

  describe "every request" do
    test "narrows the token's scopes to those its principal may hold now", %{config: config} do
      {access, _, _} =
        issue(config, %{
          subject_id: "u1",
          scopes: ["issues:read", "issues:write"],
          resource: @resource
        })

      assert "slow" in tool_names(access)
      assert call_slow(access).status == 200

      # Demoted, Ana loses `issues:write` before the token expires.
      Subject.role("u1", :viewer)
      refute "slow" in tool_names(access)
      assert call_slow(access).status == 403

      # A scope the token never held is not added by a wider role.
      {read_only, _, _} =
        issue(config, %{subject_id: "u1", scopes: ["issues:read"], resource: @resource})

      Subject.role("u1", :admin)
      refute "slow" in tool_names(read_only)
    end
  end
end
