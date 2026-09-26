defmodule Sake.Auth.CIMDTest do
  use SakeTest.AuthCase, async: false

  alias Sake.Auth.CIMD

  setup do
    bypass = Bypass.open()
    %{bypass: bypass, base: "http://localhost:#{bypass.port}"}
  end

  defp document(id, extra \\ %{}) do
    Map.merge(
      %{
        "client_id" => id,
        "client_name" => "Example MCP Client",
        "redirect_uris" => ["http://127.0.0.1:3000/callback", "http://localhost:3000/callback"],
        "grant_types" => ["authorization_code", "refresh_token"],
        "token_endpoint_auth_method" => "none",
        "client_uri" => "https://app.example",
        "logo_uri" => "https://app.example/logo.png"
      },
      extra
    )
  end

  test "fetches, validates and caches a document", %{config: config, bypass: bypass, base: base} do
    id = base <> "/client.json"
    counter = :counters.new(1, [])

    Bypass.expect(bypass, "GET", "/client.json", fn conn ->
      :counters.add(counter, 1, 1)
      assert Plug.Conn.get_req_header(conn, "accept") == ["application/json"]

      conn
      |> Plug.Conn.put_resp_header("cache-control", "max-age=120")
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, JSON.encode!(document(id)))
    end)

    assert {:ok, client} = CIMD.fetch(config, id)

    assert %{
             id: ^id,
             kind: :cimd,
             name: "Example MCP Client",
             redirect_uris: ["http://127.0.0.1:3000/callback", "http://localhost:3000/callback"],
             token_endpoint_auth_method: "none",
             client_uri: "https://app.example"
           } = client

    assert {:ok, ^client} = CIMD.fetch(config, id)
    assert :counters.get(counter, 1) == 1
  end

  test "rejects a document whose client_id differs, that lacks fields, or that is not JSON", %{
    config: config,
    bypass: bypass,
    base: base
  } do
    Bypass.expect(
      bypass,
      "GET",
      "/a.json",
      &Plug.Conn.resp(&1, 200, JSON.encode!(document("https://other.example/a.json")))
    )

    assert {:error, :invalid_document} = CIMD.fetch(config, base <> "/a.json")

    Bypass.expect(
      bypass,
      "GET",
      "/b.json",
      &Plug.Conn.resp(&1, 200, JSON.encode!(%{"client_id" => base <> "/b.json"}))
    )

    assert {:error, :invalid_document} = CIMD.fetch(config, base <> "/b.json")
    Bypass.expect(bypass, "GET", "/c.json", &Plug.Conn.resp(&1, 200, "not json"))
    assert {:error, :invalid_document} = CIMD.fetch(config, base <> "/c.json")

    Bypass.expect(
      bypass,
      "GET",
      "/d.json",
      &Plug.Conn.resp(
        &1,
        200,
        JSON.encode!(
          document(base <> "/d.json", %{"redirect_uris" => ["http://evil.example/cb"]})
        )
      )
    )

    assert {:error, :invalid_document} = CIMD.fetch(config, base <> "/d.json")

    Bypass.expect(
      bypass,
      "GET",
      "/e.json",
      &Plug.Conn.resp(
        &1,
        200,
        JSON.encode!(
          document(base <> "/e.json", %{"token_endpoint_auth_method" => "client_secret_post"})
        )
      )
    )

    assert {:error, :invalid_document} = CIMD.fetch(config, base <> "/e.json")
  end

  test "refuses redirects, oversized bodies, and errors", %{
    config: config,
    bypass: bypass,
    base: base
  } do
    Bypass.expect(bypass, "GET", "/r.json", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", base <> "/client.json")
      |> Plug.Conn.resp(302, "")
    end)

    assert {:error, :unreachable} = CIMD.fetch(config, base <> "/r.json")

    Bypass.expect(
      bypass,
      "GET",
      "/big.json",
      &Plug.Conn.resp(&1, 200, String.duplicate("x", 70_000))
    )

    assert {:error, :unreachable} = CIMD.fetch(config, base <> "/big.json")
    Bypass.expect(bypass, "GET", "/500.json", &Plug.Conn.resp(&1, 500, ""))
    assert {:error, :unreachable} = CIMD.fetch(config, base <> "/500.json")
    Bypass.down(bypass)
    assert {:error, :unreachable} = CIMD.fetch(config, base <> "/down.json")
  end

  test "never decompresses: a gzip content-encoding is not inflated", %{
    config: config,
    bypass: bypass,
    base: base
  } do
    Bypass.expect(bypass, "GET", "/bomb.json", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-encoding", "gzip")
      |> Plug.Conn.resp(200, :zlib.gzip(String.duplicate("x", 200_000)))
    end)

    assert CIMD.fetch(config, base <> "/bomb.json") in [
             {:error, :invalid_document},
             {:error, :unreachable}
           ]

    Bypass.expect(bypass, "GET", "/gz.json", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-encoding", "gzip")
      |> Plug.Conn.resp(200, :zlib.gzip(JSON.encode!(document(base <> "/gz.json"))))
    end)

    refute match?({:ok, _}, CIMD.fetch(config, base <> "/gz.json"))
  end

  test "client_id URL rules and host checks", %{config: config} do
    assert CIMD.url?("https://app.example/client.json")
    refute CIMD.url?("https://app.example")
    refute CIMD.url?("https://app.example/")
    refute CIMD.url?("http://app.example/client.json")
    refute CIMD.url?("dc_abc")
    assert {:error, :invalid_client} = CIMD.fetch(config, "https://app.example")

    refute CIMD.public_host?("127.0.0.1")
    refute CIMD.public_host?("localhost")
    refute CIMD.public_host?("10.0.0.5")
    refute CIMD.public_host?("192.168.1.1")
    refute CIMD.public_host?("172.16.0.1")
    refute CIMD.public_host?("169.254.1.1")
    refute CIMD.public_host?("::1")
    refute CIMD.public_host?("fc00::1")
    refute CIMD.public_host?("fe80::1")
    assert CIMD.public_host?("93.184.216.34")
  end

  @tag auth: [allow_insecure: false, issuer: "https://www.example.com"]
  test "with allow_insecure off, http client ids and private hosts are refused", %{config: config} do
    assert {:error, :invalid_client} = CIMD.fetch(config, "http://localhost:1/client.json")
    assert {:error, :not_allowed} = CIMD.fetch(config, "https://localhost/client.json")
  end

  @tag auth: [cimd: [policy: {:allow, ["claude.ai", "app.example"]}]]
  test "the domain allowlist", %{config: config, bypass: bypass, base: base} do
    assert {:error, :not_allowed} = CIMD.fetch(config, "https://other.example/c.json")

    Bypass.stub(
      bypass,
      "GET",
      "/c.json",
      &Plug.Conn.resp(&1, 200, JSON.encode!(document(base <> "/c.json")))
    )

    # localhost is not in the list either: the policy check runs before any
    # network request, so this stub is never called.
    assert {:error, :not_allowed} = CIMD.fetch(config, base <> "/c.json")
  end

  @tag auth: [cimd: [policy: {SakeTest.Policy, :allow?}]]
  test "a policy function", %{config: config} do
    assert {:error, :not_allowed} = CIMD.fetch(config, "https://blocked.example/c.json")
  end

  @tag auth: [cimd: false]
  test "cimd off", %{config: config} do
    assert {:error, :not_allowed} = CIMD.fetch(config, "https://app.example/c.json")
  end
end

defmodule SakeTest.Policy do
  @moduledoc false
  def allow?(%URI{host: "blocked.example"}), do: false
  def allow?(_), do: true
end
