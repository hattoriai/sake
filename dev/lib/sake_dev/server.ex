defmodule SakeDev.Server do
  @moduledoc "The example server of the development server and the tests."
  use Sake.Server,
    name: "sake-dev",
    version: Sake.version(),
    instructions:
      "An example server: echo, add, a slow tool with progress, sampling, roots, a task, issues on a board (an MCP App), and a triage prompt."

  scope "issues:read", "Read issues"
  scope "issues:write", "Change issues"

  tools [
    SakeDev.Tools.Echo,
    SakeDev.Tools.Add,
    SakeDev.Tools.Slow,
    SakeDev.Tools.Confirm,
    SakeDev.Tools.Connect,
    SakeDev.Tools.Summarize,
    SakeDev.Tools.Roots,
    SakeDev.Tools.Export,
    SakeDev.Tools.IssueBoard,
    SakeDev.Tools.IssueDetails
  ]

  resources [SakeDev.Resources.Readme, SakeDev.Resources.Issue, SakeDev.UI.IssueBoard]
  prompts [SakeDev.Prompts.Triage]

  middleware :after_call, [SakeDev.Middleware.Audit]
end
