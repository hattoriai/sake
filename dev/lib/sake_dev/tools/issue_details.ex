defmodule SakeDev.Tools.IssueDetails do
  @moduledoc false
  # Only the issue board calls this one, when a card is opened: the model
  # does not see it.
  use Sake.Tool,
    name: "issue_details",
    description: "One issue in full, for the issue board",
    scope: "issues:read",
    annotations: [read_only: true],
    ui: SakeDev.UI.IssueBoard,
    visibility: [:app]

  arg :id, :string, required: true

  @impl true
  def execute(%{id: id}, _ctx) do
    case SakeDev.Issues.fetch(id) do
      {:ok, issue} -> {:ok, issue}
      :error -> {:error, "No issue #{id}."}
    end
  end
end
