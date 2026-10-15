defmodule SakeDev.Tools.Summarize do
  @moduledoc false
  use Sake.Tool, name: "summarize", description: "Asks the client's model for a one-line summary"
  arg :text, :string, required: true

  @impl true
  def execute(%{text: text}, ctx) do
    case Sake.Sampling.create_message(ctx, :summary, [user: "Summarize in one line:\n\n" <> text],
           max_tokens: 100,
           system_prompt: "You write one-line summaries.",
           model_preferences: [hints: ["claude"], speed_priority: 0.8]
         ) do
      {:ok, %{text: summary}} -> {:ok, summary}
      {:error, :unsupported} -> {:error, "This tool needs a client that supports sampling."}
      {:error, _reason} -> {:error, "The client did not summarize."}
    end
  end
end
