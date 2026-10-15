defmodule SakeDev.Conformance.Tools.TestSampling do
  @moduledoc false
  use Sake.Tool, name: "test_sampling", description: "Asks the client's model to answer a prompt"

  arg :prompt, :string, required: true

  @impl true
  def execute(%{prompt: prompt}, ctx) do
    case Sake.Sampling.create_message(ctx, :test_sampling, [user: prompt], max_tokens: 100) do
      {:ok, %{text: text}} -> {:ok, "LLM response: #{text}"}
      {:error, :unsupported} -> {:error, "This tool needs a client that supports sampling."}
      {:error, reason} -> {:error, "Sampling failed: #{inspect(reason)}"}
    end
  end
end
