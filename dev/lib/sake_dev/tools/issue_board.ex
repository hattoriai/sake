defmodule SakeDev.Tools.IssueBoard do
  @moduledoc false
  # Shows the issues on a board (`SakeDev.UI.IssueBoard`) in a host that
  # renders MCP Apps. The JSON text of the result is what the model, and a
  # client without apps, reads; the board renders its structuredContent.
  use Sake.Tool,
    name: "issue_board",
    title: "Issue board",
    description: "Shows the issues on a board",
    scope: "issues:read",
    annotations: [read_only: true],
    ui: SakeDev.UI.IssueBoard

  arg :state, {:enum, ["open", "closed", "all"]}, default: "all"

  @impl true
  def execute(%{state: state}, _ctx) do
    issues =
      for issue <- SakeDev.Issues.all(),
          state == "all" or issue["state"] == state,
          do: Map.take(issue, ["id", "title", "state"])

    {:ok, %{issues: issues}}
  end
end
