defmodule SakeDev.Tools.Echo do
  @moduledoc false
  use Sake.Tool,
    name: "echo",
    description: "Returns the text it receives",
    annotations: [read_only: true, idempotent: true]

  arg :text, :string, required: true, description: "The text to return"
  @impl true
  def execute(%{text: text}, _ctx), do: {:ok, text}
end
