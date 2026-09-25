defmodule Sake.ServerTest do
  use ExUnit.Case, async: true

  alias Sake.Server

  test "the example server registry" do
    server = SakeDev.Server
    assert server.__sake__(:info) == %{name: "sake-dev", version: Sake.version()}
    assert server.__sake__(:instructions) =~ "example"
    assert Enum.map(server.__sake__(:tools), & &1.name) == ["echo", "add", "slow"]
    assert Enum.map(server.__sake__(:resources), & &1.uri) == ["dev://readme", "issue://{id}"]
    assert Enum.map(server.__sake__(:prompts), & &1.name) == ["triage"]

    assert server.__sake__(:scopes) == [
             {"issues:read", "Read issues"},
             {"issues:write", "Change issues"}
           ]

    assert server.__sake__(:ttl) == 300_000
    assert server.__sake__(:cache_scope) == nil
    assert server.__sake__(:page_size) == 100
    assert server.__sake__(:extensions) == %{}
  end

  test "lookups" do
    assert {:ok, %Sake.Tool.Spec{name: "add"}} = Server.tool(SakeDev.Server, "add")
    assert Server.tool(SakeDev.Server, "nope") == :error
    assert {:ok, %Sake.Resource.Spec{}, %{id: "7"}} = Server.resource(SakeDev.Server, "issue://7")
    assert {:ok, %Sake.Resource.Spec{}, %{}} = Server.resource(SakeDev.Server, "dev://readme")
    assert Server.resource(SakeDev.Server, "x://y") == :error
    assert {:ok, %Sake.Prompt.Spec{}} = Server.prompt(SakeDev.Server, "triage")
  end

  test "capabilities" do
    assert Server.capabilities(SakeDev.Server) == %{
             "tools" => %{"listChanged" => true},
             "resources" => %{"listChanged" => true, "subscribe" => true},
             "prompts" => %{"listChanged" => true},
             "completions" => %{},
             "logging" => %{}
           }
  end

  test "scope gating" do
    {:ok, slow} = Server.tool(SakeDev.Server, "slow")
    {:ok, echo} = Server.tool(SakeDev.Server, "echo")
    anon = Sake.Context.new(server: SakeDev.Server)
    assert Server.allowed?(slow, anon)
    assert Server.allowed?(echo, %{anon | token: %{}, scopes: []})
    refute Server.allowed?(slow, %{anon | token: %{}, scopes: ["issues:read"]})
    assert Server.allowed?(slow, %{anon | token: %{}, scopes: ["issues:write"]})
  end

  test "duplicate names are rejected at compile time" do
    assert_raise ArgumentError, ~r/twice/, fn ->
      defmodule Dup do
        use Sake.Server, name: "dup", version: "1"
        tools [SakeDev.Tools.Echo, SakeDev.Tools.Echo]
      end
    end
  end
end
