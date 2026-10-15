defmodule Sake.Server.LegacyTest do
  use ExUnit.Case, async: true

  alias Sake.Context
  alias Sake.Server.Legacy

  @secret String.duplicate("s", 64)

  defp ctx(rev \\ "2025-06-18", opts \\ []) do
    Context.new(
      Keyword.merge(
        [server: SakeDev.Server, secret: @secret, era: :legacy, protocol_version: rev],
        opts
      )
    )
  end

  defp call(method, params \\ %{}, ctx \\ ctx()),
    do: Legacy.handle(SakeDev.Server, {:request, 1, method, params}, ctx)

  test "initialize negotiates and returns the legacy shape" do
    params = %{
      "protocolVersion" => "2025-06-18",
      "capabilities" => %{"elicitation" => %{}},
      "clientInfo" => %{"name" => "t", "version" => "1"}
    }

    assert {:initialize, "2025-06-18", %{"elicitation" => %{}}, result} =
             call("initialize", params)

    assert result["protocolVersion"] == "2025-06-18"
    assert result["serverInfo"] == %{"name" => "sake-dev", "version" => Sake.version()}
    assert result["capabilities"]["tools"] == %{"listChanged" => true}
    assert result["instructions"] =~ "example"
    refute Map.has_key?(result, "resultType")

    assert {:initialize, "2025-11-25", _, %{"protocolVersion" => "2025-11-25"}} =
             call("initialize", %{"protocolVersion" => "2024-11-05", "capabilities" => %{}})

    assert {:initialize, "2025-11-25", _, _} =
             call("initialize", %{"protocolVersion" => "2026-07-28", "capabilities" => %{}})

    assert {:error, %{"code" => -32_602}} = call("initialize", %{})
  end

  test "lists and calls without modern fields" do
    assert {:reply, r} = call("tools/list")

    assert Enum.map(r["tools"], & &1["name"]) == [
             "echo",
             "add",
             "slow",
             "confirm",
             "connect",
             "summarize",
             "roots",
             "export",
             "issue_board"
           ]

    refute Map.has_key?(r, "ttlMs")
    refute Map.has_key?(r, "cacheScope")
    refute Map.has_key?(r, "_meta")

    assert {:reply, r} = call("tools/call", %{"name" => "echo", "arguments" => %{"text" => "hi"}})
    assert r == %{"content" => [%{"type" => "text", "text" => "hi"}], "isError" => false}

    assert {:reply, r} = call("tools/list", %{}, ctx("2025-03-26"))
    refute Map.has_key?(hd(r["tools"]), "title")
  end

  test "legacy resource not found code" do
    assert {:error, %{"code" => -32_002, "data" => %{"uri" => "issue://9"}}} =
             call("resources/read", %{"uri" => "issue://9"})
  end

  test "ping, logging, subscriptions, notifications" do
    assert {:reply, %{}} = call("ping")
    assert {:reply, %{}} = call("logging/setLevel", %{"level" => "info"})
    assert {:subscribe, "issue://1"} = call("resources/subscribe", %{"uri" => "issue://1"})

    assert {:error, %{"code" => -32_602}} =
             call("resources/subscribe", %{"uri" => "dev://readme"})

    assert {:unsubscribe, "issue://1"} = call("resources/unsubscribe", %{"uri" => "issue://1"})

    assert :noreply =
             Legacy.handle(
               SakeDev.Server,
               {:notification, "notifications/initialized", %{}},
               ctx()
             )

    assert :noreply =
             Legacy.handle(
               SakeDev.Server,
               {:notification, "notifications/roots/list_changed", %{}},
               ctx()
             )

    assert {:error, %{"code" => -32_601}} = call("server/discover")
    assert {:error, %{"code" => -32_601}} = call("subscriptions/listen")
  end
end
