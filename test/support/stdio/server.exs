# The example server over stdio, for `Sake.Client.StdioTest`: run by
# `elixir` with the test build's code paths, not compiled with the tests.
{:ok, _} = Application.ensure_all_started(:sake)
Sake.Stdio.run(SakeDev.Server)
