# A legacy stdio server that is not Sake, for `Sake.Client.StdioTest`. It
# answers `initialize` and `tools/list`; anything else before
# `initialize` gets an error in "error" mode and no answer in "silent"
# mode. In "stubborn" mode it also ignores the end of its input. In
# "flood" mode it sends a 200 KB line before its answer to `tools/list`.
[mode] = System.argv()

reply = fn message -> IO.puts(JSON.encode!(Map.put(message, "jsonrpc", "2.0"))) end

:stdio
|> IO.stream(:line)
|> Enum.reduce(false, fn line, initialized ->
  case JSON.decode!(line) do
    %{"id" => id, "method" => "initialize"} ->
      reply.(%{
        "id" => id,
        "result" => %{
          "protocolVersion" => "2025-06-18",
          "capabilities" => %{"tools" => %{}},
          "serverInfo" => %{"name" => "foreign", "version" => "1"}
        }
      })

      true

    %{"id" => id, "method" => "tools/list"} when initialized ->
      if mode == "flood",
        do:
          reply.(%{
            "method" => "notifications/message",
            "params" => %{"level" => "info", "data" => String.duplicate("x", 200_000)}
          })

      reply.(%{"id" => id, "result" => %{"tools" => [%{"name" => "t", "inputSchema" => %{}}]}})
      initialized

    %{"id" => id, "method" => _} when mode == "error" ->
      reply.(%{"id" => id, "error" => %{"code" => -32_000, "message" => "Not initialized"}})
      initialized

    _ ->
      initialized
  end
end)

if mode == "stubborn", do: Process.sleep(:infinity)
