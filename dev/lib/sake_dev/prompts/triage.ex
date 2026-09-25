defmodule SakeDev.Prompts.Triage do
  @moduledoc false
  use Sake.Prompt,
    name: "triage",
    title: "Triage an issue",
    description: "Asks for a triage of one issue"

  arg :id, :string, required: true, description: "The issue id"
  arg :tone, :string, description: "kind or direct"

  @impl true
  def get(%{id: id, tone: tone}, _ctx) do
    {:ok, [user: "Triage issue #{id} in a #{tone || "kind"} tone."],
     description: "Triage of issue #{id}"}
  end

  @impl true
  def complete("tone", partial, _ctx),
    do: {:ok, Enum.filter(["kind", "direct"], &String.starts_with?(&1, partial))}

  def complete(_, _, _), do: {:ok, []}
end
