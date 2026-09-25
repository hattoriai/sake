defmodule SakeDev.Resources.Readme do
  @moduledoc false
  use Sake.Resource,
    uri: "dev://readme",
    name: "readme",
    title: "About this server",
    mime_type: "text/markdown"

  @impl true
  def read(%{}, _ctx), do: {:ok, "# sake-dev\n\nAn example MCP server built with Sake."}
end
