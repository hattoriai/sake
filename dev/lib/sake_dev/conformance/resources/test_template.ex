defmodule SakeDev.Conformance.Resources.TestTemplate do
  @moduledoc false
  use Sake.Resource,
    uri: "test://template/{id}/data",
    name: "test-template",
    mime_type: "application/json"

  @impl true
  def read(%{id: id}, _ctx),
    do: {:ok, %{"id" => id, "templateTest" => true, "data" => "Data for ID: #{id}"}}
end
