defmodule SakeDev.Conformance.Resources.TestWatched do
  @moduledoc false
  use Sake.Resource,
    uri: "test://watched-resource",
    name: "test-watched-resource",
    mime_type: "text/plain",
    subscribe: true

  @impl true
  def read(%{}, _ctx), do: {:ok, "This resource can be subscribed to."}
end
