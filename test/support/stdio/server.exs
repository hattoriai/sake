# The example server over stdio, for `Sake.Client.StdioTest`: run by
# `elixir` with the test build's code paths, not compiled with the tests.

# The test build has the OpenTelemetry SDK, which would otherwise look
# for an exporter it does not have, and say so on standard output.
Application.put_env(:opentelemetry, :traces_exporter, :none)
{:ok, _} = Application.ensure_all_started(:sake)
Sake.Stdio.run(SakeDev.Server)
