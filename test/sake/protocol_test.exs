defmodule Sake.ProtocolTest do
  use ExUnit.Case, async: true

  alias Sake.Protocol

  test "revisions and eras" do
    assert Protocol.modern() == "2026-07-28"
    assert Protocol.legacy() == ["2025-11-25", "2025-06-18", "2025-03-26"]
    assert Protocol.supported() == ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26"]
    assert Protocol.era("2026-07-28") == :modern
    assert Protocol.era("2025-06-18") == :legacy
    assert Protocol.era("2024-11-05") == :unknown
    assert Protocol.supported?("2025-03-26")
    refute Protocol.supported?("2024-11-05")
  end

  test "legacy negotiation picks the requested revision when served, else the highest legacy" do
    assert Protocol.negotiate_legacy("2025-06-18") == "2025-06-18"
    assert Protocol.negotiate_legacy("2024-11-05") == "2025-11-25"
    assert Protocol.negotiate_legacy("2099-01-01") == "2025-11-25"
    assert Protocol.negotiate_legacy(nil) == "2025-11-25"
  end

  test "meta keys" do
    assert Protocol.meta(:protocol_version) == "io.modelcontextprotocol/protocolVersion"
    assert Protocol.meta(:client_info) == "io.modelcontextprotocol/clientInfo"
    assert Protocol.meta(:client_capabilities) == "io.modelcontextprotocol/clientCapabilities"
    assert Protocol.meta(:server_info) == "io.modelcontextprotocol/serverInfo"
    assert Protocol.meta(:log_level) == "io.modelcontextprotocol/logLevel"
    assert Protocol.meta(:subscription_id) == "io.modelcontextprotocol/subscriptionId"
  end

  test "version" do
    assert Sake.version() == Mix.Project.config()[:version]
  end
end
