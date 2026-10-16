# SakeTest.TracedServer over stdio, for `Sake.Client.TraceTest`: run by
# `elixir` with the test build's code paths. The server's spans go to the
# file named by the first argument, as an Erlang term, once its input
# closes.
[path] = System.argv()

# Before anything logs: standard output carries MCP messages only.
Sake.Stdio.log_to_stderr()
Logger.configure(level: :warning)
Application.put_env(:opentelemetry, :processors, [{:otel_simple_processor, %{}}])
Application.put_env(:opentelemetry, :traces_exporter, {SakeTest.Spans, []})
{:ok, _} = Application.ensure_all_started(:sake)
SakeTest.Spans.send_to(self())

Sake.Stdio.run(SakeTest.TracedServer)

spans =
  Stream.repeatedly(fn ->
    receive do
      {:span, span} -> span
    after
      0 -> nil
    end
  end)
  |> Enum.take_while(& &1)

File.write!(path, :erlang.term_to_binary(spans))
