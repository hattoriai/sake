defmodule SakeDev.Conformance.Tools.SlowCompute do
  @moduledoc false
  use Sake.Tool,
    name: "slow_compute",
    description: "Works for a number of seconds, as a task when the client takes one",
    task: :optional

  arg :seconds, :integer, default: 1, min: 0, max: 600
  arg :label, :string

  @impl true
  def execute(%{seconds: seconds, label: label}, ctx) do
    if wait(ctx, seconds * 1_000),
      do: {:ok, "Computed #{label || "result"} in #{seconds}s."},
      else: {:ok, "Stopped: the task was cancelled."}
  end

  # Checks for a cancellation every tenth of a second.
  defp wait(_ctx, ms) when ms <= 0, do: true

  defp wait(ctx, ms) do
    if Sake.Tasks.cancelled?(ctx) do
      false
    else
      Process.sleep(min(ms, 100))
      wait(ctx, ms - 100)
    end
  end
end
