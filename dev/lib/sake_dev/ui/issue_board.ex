defmodule SakeDev.UI.IssueBoard do
  @moduledoc false
  # An MCP App: the board the `issue_board` tool shows. The document is an
  # EEx template with its script inlined at compile time; the script
  # speaks the host's postMessage JSON-RPC itself, with no SDK and no
  # build step.
  use Sake.UI,
    uri: "ui://sake-dev/issue-board",
    name: "issue_board",
    title: "Issue board",
    description: "The open and closed issues, as cards",
    template: "issue_board.html.eex",
    prefers_border: true

  @impl true
  def assigns(_ctx), do: %{title: "Issue board"}
end
