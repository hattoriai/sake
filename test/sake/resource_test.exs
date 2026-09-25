defmodule Sake.ResourceTest do
  use ExUnit.Case, async: true

  defmodule Readme do
    use Sake.Resource,
      uri: "dev://readme",
      name: "readme",
      title: "Read me",
      mime_type: "text/markdown",
      scope: "docs:read"

    @impl true
    def read(%{}, _ctx), do: {:ok, "# hi"}
  end

  defmodule Issue do
    use Sake.Resource,
      uri: "issue://{id}",
      name: "issue",
      mime_type: "application/json",
      subscribe: true

    @impl true
    def read(%{id: id}, _ctx), do: {:ok, %{"id" => id}}
    @impl true
    def list(_ctx), do: ["issue://1", %{uri: "issue://2", name: "Issue 2"}]
  end

  test "fixed and template specs" do
    assert %Sake.Resource.Spec{
             template: false,
             uri: "dev://readme",
             scopes: ["docs:read"],
             mime_type: "text/markdown"
           } = Readme.spec()

    assert %Sake.Resource.Spec{template: true, uri: "issue://{id}", subscribe: true} =
             Issue.spec()
  end

  test "matching" do
    assert Sake.Resource.Spec.match(Readme.spec(), "dev://readme") == {:ok, %{}}
    assert Sake.Resource.Spec.match(Readme.spec(), "dev://other") == :error
    assert Sake.Resource.Spec.match(Issue.spec(), "issue://42") == {:ok, %{id: "42"}}
    assert Sake.Resource.Spec.match(Issue.spec(), "issue://42/x") == :error
  end

  test "wire form" do
    assert Sake.Resource.Spec.to_wire(Readme.spec(), "2026-07-28") ==
             %{
               "uri" => "dev://readme",
               "name" => "readme",
               "title" => "Read me",
               "mimeType" => "text/markdown"
             }

    assert Sake.Resource.Spec.template_to_wire(Issue.spec(), "2026-07-28") ==
             %{
               "uriTemplate" => "issue://{id}",
               "name" => "issue",
               "mimeType" => "application/json"
             }
  end
end
