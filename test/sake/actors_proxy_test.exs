defmodule Sake.ActorsProxyTest do
  # A proxy is a named process: this test does not run beside others.
  use ExUnit.Case, async: false

  import Sake.Test

  alias Sake.Actors.Actor
  alias Sake.Client.ToolResult
  alias SakeTest.{HTTP, Upstream}

  defmodule Actors do
    @moduledoc false
    @behaviour Sake.Actors

    @impl true
    def list(_ctx), do: [%Actor{id: "agent:1", name: "Ada"}]
  end

  defmodule Proxy do
    @moduledoc false
    use Sake.Proxy, name: "actors-proxy", version: "1", upstream: "http://127.0.0.1:1/mcp"
  end

  defmodule Gateway do
    @moduledoc false
    use Sake.Server, name: "actors-gateway", version: "1"
    mount Sake.ActorsProxyTest.Proxy, prefix: "up"
    actors(Actors)
  end

  test "a proxied tool gets `as` from the gateway, and its upstream never sees it" do
    url = HTTP.start(Upstream.Router) <> "/mcp"
    start_supervised!({Proxy, upstream: url})
    client = connect(Gateway)

    assert {:ok, tools} = list_tools(client)
    assert Enum.find(tools, &(&1.name == "up_add")).input_schema["properties"]["as"]

    # The upstream refuses arguments it does not know: `as` is not among them.
    assert {:ok, %ToolResult{structured: %{"sum" => 3}}} =
             call_tool(client, "up_add", %{"a" => 1, "b" => 2, "as" => "agent:1"})

    assert {:ok, %ToolResult{is_error: true, text: "You may not act as" <> _}} =
             call_tool(client, "up_add", %{"a" => 1, "b" => 2, "as" => "agent:9"})
  end
end
