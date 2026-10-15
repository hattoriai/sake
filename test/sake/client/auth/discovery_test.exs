defmodule Sake.Client.Auth.DiscoveryTest do
  use ExUnit.Case, async: true
  alias Sake.Client.Auth.Discovery

  test "resource metadata: the path-inserted well-known URI, then the root one" do
    assert Discovery.resource_metadata_urls("https://example.com/public/mcp") == [
             "https://example.com/.well-known/oauth-protected-resource/public/mcp",
             "https://example.com/.well-known/oauth-protected-resource"
           ]

    assert Discovery.resource_metadata_urls("https://Example.com:8443/") == [
             "https://example.com:8443/.well-known/oauth-protected-resource"
           ]
  end

  test "authorization server metadata: RFC 8414 and OpenID Connect, path-inserted then appended" do
    assert Discovery.metadata_urls("https://auth.example.com/tenant1") == [
             "https://auth.example.com/.well-known/oauth-authorization-server/tenant1",
             "https://auth.example.com/.well-known/openid-configuration/tenant1",
             "https://auth.example.com/tenant1/.well-known/openid-configuration"
           ]

    assert Discovery.metadata_urls("https://auth.example.com") == [
             "https://auth.example.com/.well-known/oauth-authorization-server",
             "https://auth.example.com/.well-known/openid-configuration"
           ]
  end

  test "a resource identifier matches its endpoint or a path prefix of it on the same origin" do
    url = "https://mcp.example.com/server/mcp"

    assert Discovery.resource_matches?("https://mcp.example.com/server/mcp", url)
    assert Discovery.resource_matches?("https://mcp.example.com", url)
    assert Discovery.resource_matches?("HTTPS://MCP.example.com/server", url)
    assert Discovery.resource_matches?("https://mcp.example.com/server/mcp/", url)

    refute Discovery.resource_matches?("https://evil.example.com/server/mcp", url)
    refute Discovery.resource_matches?("http://mcp.example.com/server/mcp", url)
    refute Discovery.resource_matches?("https://mcp.example.com:8443/server/mcp", url)
    refute Discovery.resource_matches?("https://mcp.example.com/serv", url)
    refute Discovery.resource_matches?("https://mcp.example.com/other/mcp", url)
    refute Discovery.resource_matches?("https://mcp.example.com/server/mcp#x", url)
    refute Discovery.resource_matches?("mcp.example.com/server/mcp", url)
  end

  test "the canonical URI: lowercase scheme and host, no default port, no trailing slash" do
    assert Discovery.canonical("HTTPS://MCP.Example.com:443/Mcp/") ==
             "https://mcp.example.com/Mcp"

    assert Discovery.canonical("http://127.0.0.1:4000/mcp") == "http://127.0.0.1:4000/mcp"
    assert Discovery.canonical("https://mcp.example.com/") == "https://mcp.example.com"
    assert Discovery.canonical("http://[::1]:4000/mcp") == "http://[::1]:4000/mcp"
  end
end
