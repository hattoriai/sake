defmodule SakeDev.Gateway do
  @moduledoc false
  # An example of composing and proxying (`/gateway/mcp`, behind the
  # development server's login): the example server mounted under `dev`,
  # and the conformance fixtures of `/open/mcp`, an endpoint without
  # authorization, proxied under `open`. See `guides/composing.md`.
  use Sake.Server,
    name: "sake-gateway",
    version: Sake.version(),
    instructions: "One endpoint for the example server and a proxied one."

  mount SakeDev.Server, prefix: "dev"
  mount SakeDev.Gateway.Open, prefix: "open"

  defmodule Open do
    @moduledoc false
    # Its upstream is this development server's own open endpoint; a
    # host's would be another server altogether. Started by `dev.exs`.
    use Sake.Proxy,
      name: "open",
      version: Sake.version(),
      upstream: "http://localhost:4000/open/mcp",
      tools: [only: ["test_simple_text", "test_tool_with_progress", "test_elicitation"]],
      prompts: [only: ["test_simple_prompt"]],
      scope: "issues:read"
  end
end
