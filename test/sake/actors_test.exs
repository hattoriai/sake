defmodule Sake.ActorsTest do
  use ExUnit.Case, async: true

  import Sake.Test

  alias Sake.Actors.Actor
  alias Sake.Client.ToolResult

  # The principal (`ctx.scope`) is a map: its `:agents` are who it may act
  # as, and `:default` the id of a call without `as`.

  defmodule Actors do
    @moduledoc false
    @behaviour Sake.Actors

    @impl true
    def list(%{scope: %{agents: agents}}) do
      for {id, name} <- agents,
          do: %Actor{id: id, name: name, instructions: "You are #{name}.", data: {:agent, id}}
    end

    @impl true
    def default(%{scope: %{default: id}} = ctx) when is_binary(id),
      do: Enum.find(list(ctx), &(&1.id == id))

    def default(_ctx), do: nil
  end

  defmodule Whoami do
    @moduledoc false
    use Sake.Tool, name: "whoami", description: "Says who acts"
    arg :text, :string

    @impl true
    def execute(args, ctx) do
      who = if ctx.actor, do: "#{ctx.actor.name} #{inspect(ctx.actor.data)}", else: "the person"
      {:ok, "#{args[:text]} by #{who}"}
    end
  end

  defmodule OwnAs do
    @moduledoc false
    use Sake.Tool, name: "own_as", description: "Has an argument named as"
    arg :as, :string, required: true

    @impl true
    def execute(%{as: as}, ctx), do: {:ok, "as=#{as} actor=#{inspect(ctx.actor)}"}
  end

  defmodule Server do
    @moduledoc false
    use Sake.Server, name: "actors-test", version: "1.0.0"
    tools [Whoami, OwnAs]
    actors(Actors)
  end

  defmodule Plain do
    @moduledoc false
    use Sake.Server, name: "plain-test", version: "1.0.0"
    tools [Whoami]
  end

  defmodule Inner do
    @moduledoc false
    use Sake.Server, name: "inner-test", version: "1.0.0"
    tools [Whoami]
  end

  defmodule Gateway do
    @moduledoc false
    use Sake.Server, name: "gateway-test", version: "1.0.0"
    mount Inner, prefix: "inner"
    actors(Actors)
  end

  defp scope(opts \\ []),
    do: Map.merge(%{agents: [{"agent:1", "Ada"}, {"agent:2", "Bo"}], default: nil}, Map.new(opts))

  for era <- [:modern, :legacy] do
    describe "#{era}" do
      @era era

      test "the server lists list_actors and act_as, and `as` on its other tools" do
        client = connect(Server, era: @era, scope: scope())
        assert {:ok, tools} = list_tools(client)
        tools = Map.new(tools, &{&1.name, &1})

        assert Map.keys(tools) |> Enum.sort() == ~w(act_as list_actors own_as whoami)
        assert %{"type" => "string"} = tools["whoami"].input_schema["properties"]["as"]
        refute Map.has_key?(tools["list_actors"].input_schema["properties"] || %{}, "as")
        refute Map.has_key?(tools["act_as"].input_schema["properties"], "as")
        # A tool's own `as` stays its own.
        assert tools["own_as"].input_schema["properties"]["as"]["description"] == nil
      end

      test "a call without `as` acts as the default: the person, or the host's" do
        client = connect(Server, era: @era, scope: scope())

        assert {:ok, %ToolResult{text: "hi by the person"}} =
                 call_tool(client, "whoami", %{"text" => "hi"})

        client = connect(Server, era: @era, scope: scope(default: "agent:2"))

        assert {:ok, %ToolResult{text: ~s|hi by Bo {:agent, "agent:2"}|}} =
                 call_tool(client, "whoami", %{"text" => "hi"})
      end

      test "a call with `as` acts as that actor, which the tool reads in ctx.actor" do
        client = connect(Server, era: @era, scope: scope())

        assert {:ok, %ToolResult{is_error: false, text: ~s|hi by Ada {:agent, "agent:1"}|}} =
                 call_tool(client, "whoami", %{"text" => "hi", "as" => "agent:1"})
      end

      test "an `as` the principal may not act as is a tool error" do
        client = connect(Server, era: @era, scope: scope())

        assert {:ok, %ToolResult{is_error: true, text: text}} =
                 call_tool(client, "whoami", %{"text" => "hi", "as" => "agent:9"})

        assert text =~ "You may not act as agent:9"
        assert text =~ "list_actors"

        assert {:ok, %ToolResult{is_error: true}} = call_tool(client, "whoami", %{"as" => 3})
      end

      test "list_actors lists the actors and the default, act_as returns the persona" do
        client = connect(Server, era: @era, scope: scope(default: "agent:1"))

        assert {:ok, %ToolResult{structured: listed}} = call_tool(client, "list_actors")

        assert listed == %{
                 "actors" => [
                   %{"id" => "agent:1", "name" => "Ada", "default" => true},
                   %{"id" => "agent:2", "name" => "Bo", "default" => false}
                 ],
                 "default" => "agent:1"
               }

        assert {:ok, %ToolResult{structured: acted, text: text}} =
                 call_tool(client, "act_as", %{"id" => "agent:2"})

        assert acted == %{
                 "id" => "agent:2",
                 "name" => "Bo",
                 "as" => "agent:2",
                 "instructions" => "You are Bo."
               }

        assert text =~ ~s|Pass "as": "agent:2" to every tool.|
        assert text =~ "You are Bo."

        assert {:ok, %ToolResult{is_error: true}} =
                 call_tool(client, "act_as", %{"id" => "agent:9"})
      end

      test "a tool with its own `as` keeps it, and acts as the default" do
        client = connect(Server, era: @era, scope: scope())

        assert {:ok, %ToolResult{text: "as=x actor=nil"}} =
                 call_tool(client, "own_as", %{"as" => "x"})
      end

      test "a server's actors apply to the tools of the servers it mounts" do
        client = connect(Gateway, era: @era, scope: scope())
        assert {:ok, tools} = list_tools(client)
        inner = Enum.find(tools, &(&1.name == "inner_whoami"))
        assert inner.input_schema["properties"]["as"]

        assert {:ok, %ToolResult{text: ~s|hi by Bo {:agent, "agent:2"}|}} =
                 call_tool(client, "inner_whoami", %{"text" => "hi", "as" => "agent:2"})
      end

      test "a server without actors has no `as`, and refuses one" do
        client = connect(Plain, era: @era, scope: scope())
        assert {:ok, [tool]} = list_tools(client)
        refute Map.has_key?(tool.input_schema["properties"], "as")

        assert {:ok, %ToolResult{is_error: true, text: text}} =
                 call_tool(client, "whoami", %{"as" => "agent:1"})

        assert text =~ "Invalid arguments"
      end
    end
  end
end
