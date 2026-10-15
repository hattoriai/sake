defmodule SakeDev.Conformance.Tools.ProtocolErrorJob do
  @moduledoc false
  use Sake.Tool,
    name: "protocol_error_job",
    description: "Raises, which fails its task with a JSON-RPC error",
    task: :optional

  @impl true
  def execute(%{}, _ctx), do: raise("protocol_error_job always raises")
end
