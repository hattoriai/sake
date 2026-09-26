defmodule SakeDev.Conformance.Resources.TestStaticText do
  @moduledoc false
  use Sake.Resource, uri: "test://static-text", name: "test-static-text", mime_type: "text/plain"

  @impl true
  def read(%{}, _ctx), do: {:ok, "This is the content of the static text resource."}
end
