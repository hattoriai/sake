defmodule SakeDev.Tools.Roots do
  @moduledoc false
  use Sake.Tool, name: "roots", description: "Lists the folders the client shares"

  @impl true
  def execute(%{}, ctx) do
    case Sake.Roots.list(ctx) do
      {:ok, roots} -> {:ok, Enum.map_join(roots, "\n", &"#{&1.uri} (#{&1.name || "unnamed"})")}
      {:error, :unsupported} -> {:error, "This tool needs a client that shares its roots."}
      {:error, _reason} -> {:error, "The client did not list its roots."}
    end
  end
end
