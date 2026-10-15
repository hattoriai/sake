defmodule SakeDev.Conformance.Tools.TestInputRequiredResultCapabilities do
  @moduledoc false
  # Asks for everything at once: a request whose capability the client did
  # not declare comes back `{:error, :unsupported}` without being asked.
  use Sake.Tool,
    name: "test_input_required_result_capabilities",
    description: "Asks only what the client declared it can answer"

  @impl true
  def execute(%{}, ctx) do
    results =
      Sake.Input.all(ctx, [
        &Sake.Elicit.form(&1, :user_name, "What is your name?", %{
          "type" => "object",
          "properties" => %{"name" => %{"type" => "string"}}
        }),
        &Sake.Sampling.create_message(&1, :greeting, [user: "Generate a greeting"],
          max_tokens: 50
        ),
        &Sake.Roots.list(&1, :client_roots)
      ])

    {:ok, "Answers: #{inspect(results)}"}
  end
end
