defmodule SakeDev.Conformance.Tools.TestMissingCapability do
  @moduledoc false
  # Needs sampling, and says so with -32021 when the client did not declare it.
  use Sake.Tool,
    name: "test_missing_capability",
    description: "Needs a client that supports sampling"

  @impl true
  def execute(%{}, ctx) do
    case Sake.Sampling.create_message(ctx, :answer, [user: "Say hello"], max_tokens: 20) do
      {:ok, %{text: text}} -> {:ok, text}
      {:error, :unsupported} -> {:error, {:missing_capability, %{"sampling" => %{}}}}
      {:error, reason} -> {:error, "Sampling failed: #{inspect(reason)}"}
    end
  end
end
