defmodule SakeDev.Conformance.Tools.TestInputRequiredResultListRoots do
  @moduledoc false
  use Sake.Tool,
    name: "test_input_required_result_list_roots",
    description: "Lists the client's roots"

  @impl true
  def execute(%{}, ctx) do
    case Sake.Roots.list(ctx, :client_roots) do
      {:ok, roots} -> {:ok, "Roots: " <> Enum.map_join(roots, ", ", & &1.uri)}
      {:error, reason} -> {:error, "No roots: #{inspect(reason)}"}
    end
  end
end
