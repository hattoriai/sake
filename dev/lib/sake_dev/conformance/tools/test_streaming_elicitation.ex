defmodule SakeDev.Conformance.Tools.TestStreamingElicitation do
  @moduledoc false
  # server-stateless: a streamed call that needs input must answer with an
  # input-required result, never with a request of its own on the stream.
  use Sake.Tool,
    name: "test_streaming_elicitation",
    description: "Asks for input from a streamed call",
    stream: true

  @impl true
  def execute(%{}, ctx) do
    schema = %{"type" => "object", "properties" => %{"answer" => %{"type" => "string"}}}

    case Sake.Elicit.form(ctx, :answer, "Anything to add?", schema) do
      {:ok, content} -> {:ok, "Answer: #{inspect(content)}"}
      {:error, :unsupported} -> {:error, "This tool needs a client that supports elicitation."}
      _ -> {:ok, "No answer."}
    end
  end
end
