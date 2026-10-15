defmodule Mix.Tasks.Sake.Stdio do
  @shortdoc "Serves a Sake server over standard input and output"

  @moduledoc """
  Serves a `Sake.Server` module over standard input and output, for a
  client that launches the server as a subprocess:

      mix sake.stdio MyApp.MCP

  The task compiles and starts the application without writing to
  standard output (Mix's own messages are silenced, and the default
  `Logger` handler moves to standard error), then runs `Sake.Stdio.run/2`
  until standard input closes. Compiler warnings and errors still go to
  standard error.
  """

  use Mix.Task

  @impl true
  def run(args) do
    case OptionParser.parse(args, strict: []) do
      {[], [server], []} ->
        Mix.shell(Mix.Shell.Quiet)
        Sake.Stdio.log_to_stderr()
        Mix.Task.run("app.start")
        Sake.Stdio.run(server!(server))

      _ ->
        Mix.raise("Usage: mix sake.stdio MyApp.MCP")
    end
  end

  defp server!(name) do
    module = Module.concat([name])

    if Code.ensure_loaded?(module) and function_exported?(module, :__sake__, 1),
      do: module,
      else: Mix.raise("#{name} is not a Sake.Server module")
  end
end
