defmodule Sake.Auth.ExtensionsTest.Personal do
  @moduledoc false
  # The development subject without machine clients or JWT grants.
  @behaviour Sake.Auth.Subject

  @impl true
  defdelegate from_conn(conn), to: SakeDev.Subject
  @impl true
  defdelegate id(person), to: SakeDev.Subject
  @impl true
  defdelegate fetch(id), to: SakeDev.Subject
  @impl true
  defdelegate display(person), to: SakeDev.Subject
end

defmodule Sake.Auth.ExtensionsTest.Mounting do
  @moduledoc false
  use Sake.Server, name: "mounting", version: "1", extensions: %{"com.example/own" => %{}}

  mount SakeDev.Server, prefix: "dev"
end

defmodule Sake.Auth.ExtensionsTest do
  use SakeTest.AuthCase, async: false

  alias Sake.Auth.ExtensionsTest.{Mounting, Personal}
  alias SakeTest.{LegacyClient, ModernClient}

  @client_credentials "io.modelcontextprotocol/oauth-client-credentials"
  @enterprise "io.modelcontextprotocol/enterprise-managed-authorization"
  @idp "https://idp.example"

  defp bearer(config) do
    {access, _, _} = issue(config, %{scopes: ["issues:read"]})
    {"authorization", "Bearer " <> access}
  end

  defp discover(config, plug_opts \\ []) do
    conn =
      ModernClient.post(ModernClient.opts([auth: true] ++ plug_opts), "server/discover", %{},
        headers: [bearer(config)]
      )

    assert conn.status == 200, conn.resp_body
    ModernClient.json(conn)["result"]
  end

  describe "server/discover" do
    test "an endpoint with auth: advertises the grants its authorization server offers, with the server's own extensions",
         %{config: config} do
      result = discover(config)
      ext = result["capabilities"]["extensions"]

      assert ext[@client_credentials] == %{}
      refute Map.has_key?(ext, @enterprise)
      # MCP Apps and the tasks extension are still there.
      assert Map.has_key?(ext, Sake.UI.extension())
      assert Map.has_key?(ext, Sake.Tasks.extension())
      assert result["cacheScope"] == "private"
    end

    test "the same server on an endpoint without auth: advertises none" do
      conn = ModernClient.post(ModernClient.opts(), "server/discover")
      ext = ModernClient.json(conn)["result"]["capabilities"]["extensions"]

      refute Map.has_key?(ext, @client_credentials)
      refute Map.has_key?(ext, @enterprise)
      assert Map.has_key?(ext, Sake.UI.extension())
    end

    @tag auth: [trusted_issuers: [[issuer: @idp, clients: :any]]]
    test "a trusted ID-JAG issuer adds enterprise-managed authorization", %{config: config} do
      ext = discover(config)["capabilities"]["extensions"]

      assert ext[@client_credentials] == %{}
      assert ext[@enterprise] == %{}
    end

    @tag auth: [trusted_issuers: [[issuer: @idp, profile: :workload, clients: :any]]]
    test "a workload issuer alone adds no extension", %{config: config} do
      ext = discover(config)["capabilities"]["extensions"]

      refute Map.has_key?(ext, @enterprise)
    end

    @tag auth: [subject: Personal]
    test "a subject module without client_principal/1 offers no client credentials", %{
      config: config
    } do
      ext = discover(config)["capabilities"]["extensions"]

      refute Map.has_key?(ext, @client_credentials)
      refute Map.has_key?(ext, @enterprise)
    end

    test "a mounted server is advertised by its parent's endpoint", %{config: config} do
      ext = discover(config, server: Mounting)["capabilities"]["extensions"]

      assert ext[@client_credentials] == %{}
      assert ext["com.example/own"] == %{}
    end
  end

  describe "the legacy initialize" do
    test "an endpoint with auth: advertises the extensions next to MCP Apps", %{config: config} do
      conn =
        Plug.Test.conn(
          :post,
          "/mcp",
          JSON.encode!(
            Sake.JSONRPC.request(0, "initialize", %{
              "protocolVersion" => "2025-11-25",
              "capabilities" => %{},
              "clientInfo" => %{"name" => "legacy-test", "version" => "0"}
            })
          )
        )
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("accept", "application/json, text/event-stream")
        |> Plug.Conn.put_req_header("mcp-protocol-version", "2025-11-25")
        |> Plug.Conn.put_req_header("authorization", elem(bearer(config), 1))
        |> Sake.Plug.call(ModernClient.opts(auth: true))

      assert conn.status == 200, conn.resp_body
      ext = LegacyClient.json(conn)["result"]["capabilities"]["extensions"]

      assert ext[@client_credentials] == %{}
      assert Map.has_key?(ext, Sake.UI.extension())
    end

    test "an endpoint without auth: advertises none" do
      session = LegacyClient.initialize(ModernClient.opts(), "2025-11-25")
      ext = session.result["capabilities"]["extensions"]

      refute Map.has_key?(ext, @client_credentials)
    end
  end
end
