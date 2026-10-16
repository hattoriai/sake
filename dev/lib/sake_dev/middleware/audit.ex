defmodule SakeDev.Middleware.Audit do
  @moduledoc false
  # The development server's example middleware: logs every tool call, who
  # made it, with which arguments, and whether the tool failed. See
  # `guides/middleware.md`.
  @behaviour Sake.Middleware

  require Logger

  @impl true
  def init(opts), do: Keyword.get(opts, :level, :info)

  @impl true
  def call(%{tool: tool, arguments: args, result: result, ctx: ctx} = payload, level) do
    Logger.log(
      level,
      "tools/call #{tool.name} by #{inspect(ctx.scope)} with #{inspect(args)}" <>
        if(result["isError"], do: " failed", else: "")
    )

    {:cont, payload}
  end
end
