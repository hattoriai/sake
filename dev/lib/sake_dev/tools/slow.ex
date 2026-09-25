defmodule SakeDev.Tools.Slow do
  @moduledoc false
  use Sake.Tool,
    name: "slow",
    description: "Counts to n, reporting progress",
    scope: "issues:write",
    stream: true

  arg :n, :integer, default: 3, min: 1, max: 100
  arg :delay_ms, :integer, default: 10, min: 0, max: 1000

  @impl true
  def execute(%{n: n, delay_ms: d}, ctx) do
    for i <- 1..n do
      Process.sleep(d)
      ctx.progress.(i, {n, nil})
    end

    {:ok, "counted to #{n}"}
  end
end
