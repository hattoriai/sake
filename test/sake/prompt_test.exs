defmodule Sake.PromptTest do
  use ExUnit.Case, async: true

  defmodule Triage do
    use Sake.Prompt, name: "triage", title: "Triage", description: "Triage an issue"
    arg :id, :string, required: true, description: "Issue id"
    arg :tone, :string
    @impl true
    def get(%{id: id}, _ctx), do: {:ok, [user: "Triage #{id}"]}
    @impl true
    def complete("tone", partial, _ctx),
      do: {:ok, Enum.filter(["kind", "direct"], &String.starts_with?(&1, partial))}
  end

  test "spec and wire" do
    spec = Triage.spec()

    assert spec.args == [
             %{name: "id", description: "Issue id", required: true},
             %{name: "tone", description: nil, required: false}
           ]

    assert Sake.Prompt.Spec.to_wire(spec, "2026-07-28") == %{
             "name" => "triage",
             "title" => "Triage",
             "description" => "Triage an issue",
             "arguments" => [
               %{"name" => "id", "description" => "Issue id", "required" => true},
               %{"name" => "tone", "required" => false}
             ]
           }
  end

  test "prompt args must be strings" do
    assert_raise ArgumentError, ~r/prompt arguments/, fn ->
      defmodule BadArg do
        use Sake.Prompt, name: "bad", description: "x"
        arg :n, :integer
        def get(_, _), do: {:ok, []}
      end
    end
  end
end
