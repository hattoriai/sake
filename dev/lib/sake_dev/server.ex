defmodule SakeDev.Server do
  @moduledoc "The example server of the development server and the tests."
  use Sake.Server,
    name: "sake-dev",
    version: Sake.version(),
    instructions:
      "An example server: echo, add, a slow tool with progress, issues, and a triage prompt."

  scope "issues:read", "Read issues"
  scope "issues:write", "Change issues"

  tools [
    SakeDev.Tools.Echo,
    SakeDev.Tools.Add,
    SakeDev.Tools.Slow,
    SakeDev.Tools.Confirm,
    SakeDev.Tools.Connect
  ]

  resources [SakeDev.Resources.Readme, SakeDev.Resources.Issue]
  prompts [SakeDev.Prompts.Triage]
end
