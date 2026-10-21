defmodule Sake.AbsentTest do
  # A tool that tells a left-out argument from one sent as null (`absent: :omit`).
  use ExUnit.Case, async: true

  import Sake.Test

  defmodule Seen do
    use Sake.Tool, name: "seen", description: "Says which arguments it got", absent: :omit
    arg :value, :any
    arg :before, :any

    @impl true
    def execute(args, _ctx),
      do: {:ok, %{"got" => args |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()}}
  end

  defmodule Filled do
    use Sake.Tool, name: "filled", description: "Gets every argument, nil when left out"
    arg :value, :any
    arg :before, :any

    @impl true
    def execute(args, _ctx),
      do: {:ok, %{"got" => args |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()}}
  end

  defmodule Server do
    use Sake.Server, name: "absent-test", version: "0.0.0"
    tools([Seen, Filled])
  end

  test "a tool with absent: :omit gets what the client sent" do
    client = connect(Server)

    assert {:ok, %{structured: %{"got" => ["value"]}}} =
             call_tool(client, "seen", %{"value" => 1})

    assert {:ok, %{structured: %{"got" => ["before", "value"]}}} =
             call_tool(client, "seen", %{"value" => 1, "before" => nil})

    assert {:ok, %{structured: %{"got" => ["before", "value"]}}} =
             call_tool(client, "filled", %{"value" => 1})
  end

  test "absent is :nil or :omit" do
    assert_raise ArgumentError, ~r/absent: must be :nil or :omit/, fn ->
      defmodule Bad do
        use Sake.Tool, name: "bad", description: "x", absent: :maybe
      end
    end
  end
end
