defmodule SakeTest.StdioScript do
  @moduledoc false
  # The scripts of test/support/stdio, as `Sake.Client` targets: run by
  # `elixir` with this build's code paths, so the server is the compiled
  # test code itself.

  @doc "The development server over stdio."
  def server, do: script("server")

  @doc "A script of test/support/stdio, with its arguments."
  def script(name, args \\ []) do
    paths =
      Mix.Project.build_path()
      |> Path.join("lib/*/ebin")
      |> Path.wildcard()
      |> Enum.flat_map(&["-pa", &1])

    {:stdio, System.find_executable("elixir"),
     paths ++ [Path.expand("stdio/#{name}.exs", __DIR__) | args]}
  end
end
