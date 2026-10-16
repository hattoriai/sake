defmodule SakeTest.TracedServer do
  @moduledoc false
  # A server whose tools open spans of their own, for the tracing tests,
  # in this VM and behind `Sake.Stdio` in another (test/support/stdio).

  defmodule Traced do
    @moduledoc false
    # A span inside the tool, as Ecto or Req would open one, and the
    # baggage the tool sees.
    use Sake.Tool, name: "traced", description: "Opens a span and returns its baggage"
    arg :note, :string

    @impl true
    def execute(_args, _ctx) do
      SakeTest.TracedServer.span("inside the tool", fn ->
        baggage = Map.new(:otel_baggage.get_all(), fn {k, {v, _metadata}} -> {k, v} end)
        {:ok, %{"baggage" => baggage}}
      end)
    end
  end

  defmodule TracedTask do
    @moduledoc false
    use Sake.Tool, name: "traced_task", description: "A task that opens a span", task: :optional

    @impl true
    def execute(_args, _ctx),
      do: SakeTest.TracedServer.span("inside the task", fn -> {:ok, "done"} end)
  end

  defmodule Failing do
    @moduledoc false
    use Sake.Tool, name: "failing", description: "Always a tool error"

    @impl true
    def execute(_args, _ctx), do: {:error, "It failed."}
  end

  defmodule Boom do
    @moduledoc false
    use Sake.Tool, name: "boom", description: "Raises"

    @impl true
    def execute(_args, _ctx), do: raise("kaboom")
  end

  defmodule OnlyTask do
    @moduledoc false
    use Sake.Tool, name: "only_task", description: "Runs only as a task", task: :required

    @impl true
    def execute(_args, _ctx), do: {:ok, "done"}
  end

  use Sake.Server, name: "traced", version: "1.0.0"

  @doc false
  def span(name, fun) do
    :otel_tracer.with_span(:opentelemetry.get_tracer(:sake_test), name, %{}, fn _ -> fun.() end)
  end

  tools [Traced, TracedTask, Failing, Boom, OnlyTask, SakeDev.Tools.Confirm]
  resources [SakeDev.Resources.Readme]
  prompts [SakeDev.Prompts.Triage]
end
