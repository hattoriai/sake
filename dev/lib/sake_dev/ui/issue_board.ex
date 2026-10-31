defmodule SakeDev.UI.IssueBoard do
  @moduledoc false
  # An MCP App: the board the `issue_board` tool shows. The document is an
  # EEx template with its script inlined at compile time; the script
  # speaks the host's postMessage JSON-RPC itself, with no SDK and no
  # build step. The names it calls its tools by come from `assigns/1`
  # (`Sake.UI.names/2`), so that it keeps working when a host mounts the
  # server under a prefix.
  use Sake.UI,
    uri: "ui://sake-dev/issue-board",
    name: "issue_board",
    title: "Issue board",
    description: "The open and closed issues, as cards",
    template: "issue_board.html.eex",
    prefers_border: true

  @impl true
  def assigns(ctx) do
    %{title: "Issue board", names: Sake.UI.names(ctx, tools: [SakeDev.Tools.IssueDetails])}
  end
end
