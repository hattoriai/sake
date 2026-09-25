defmodule SakeDev.Tools.Add do
  @moduledoc false
  use Sake.Tool,
    name: "add",
    description: "Adds two numbers",
    annotations: [read_only: true, idempotent: true]

  arg :a, :number, required: true
  arg :b, :number, required: true
  arg :precision, :integer, header: "Precision", min: 0, max: 10

  output do
    arg :sum, :number, required: true
  end

  @impl true
  def execute(%{a: a, b: b, precision: p}, _ctx) do
    sum = a + b
    {:ok, %{sum: if(p, do: Float.round(sum / 1, p), else: sum)}}
  end
end
