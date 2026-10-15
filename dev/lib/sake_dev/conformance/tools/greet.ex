defmodule SakeDev.Conformance.Tools.Greet do
  @moduledoc false
  # The tasks extension scenarios' synchronous tool.
  use Sake.Tool, name: "greet", description: "Greets by name, synchronously"

  arg :name, :string, required: true

  @impl true
  def execute(%{name: name}, _ctx), do: {:ok, "Hello, #{name}!"}
end
