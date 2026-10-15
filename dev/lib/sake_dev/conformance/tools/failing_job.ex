defmodule SakeDev.Conformance.Tools.FailingJob do
  @moduledoc false
  use Sake.Tool,
    name: "failing_job",
    description: "Runs only as a task, and reports a tool error after a second",
    task: :required

  @impl true
  def execute(%{}, _ctx) do
    Process.sleep(1_000)
    {:error, "The job failed."}
  end
end
