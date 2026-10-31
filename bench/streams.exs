# Open streams: what one `subscriptions/listen` stream costs the server in
# memory, and how long one broadcast (`Sake.Server.notify_list_changed/2`)
# takes to reach every stream.
#
#     mix run bench/streams.exs
#
# The streams are opened by bench/streams_client.exs, a separate OS
# process, so the server's memory counts only the server. Each stream is
# a TCP connection on both sides: raise the open-file limit (`ulimit -n`)
# above the largest count, twice over when client and server share a
# machine.
#
# Options (environment):
#
#   * `BENCH_STREAMS` — stream counts, comma-separated (default 1000,5000,9000)
#   * `BENCH_ROUNDS` — broadcasts per count (default 5)
#   * `BENCH_PORT` — the port the server listens on (default 4041)
#   * `BENCH_JSON` — append the results to this JSON summary
#
# See guides/performance.md for how to read the numbers.

Code.require_file("support.exs", __DIR__)

port = String.to_integer(System.get_env("BENCH_PORT", "4041"))
rounds = String.to_integer(System.get_env("BENCH_ROUNDS", "5"))

counts =
  System.get_env("BENCH_STREAMS", "1000,5000,9000")
  |> String.split(",", trim: true)
  |> Enum.map(&String.to_integer(String.trim(&1)))

Bench.start_sake()

{:ok, _} =
  Bandit.start_link(
    plug: {Sake.Plug, server: Bench.Server, secret: Bench.secret()},
    ip: :loopback,
    port: port,
    thousand_island_options: [num_connections: 100_000]
  )

body_file = Path.join(System.tmp_dir!(), "sake-bench-listen-#{System.os_time()}.json")

File.write!(
  body_file,
  Bench.modern_body("listen", "subscriptions/listen", %{
    "notifications" => %{"toolsListChanged" => true}
  })
)

memory = fn ->
  Enum.each(Process.list(), &:erlang.garbage_collect/1)
  {:erlang.memory(:total), :erlang.memory(:processes), length(Process.list())}
end

client = fn count ->
  Port.open({:spawn_executable, System.find_executable("elixir")}, [
    :binary,
    {:line, 1024},
    :exit_status,
    args: [Path.join(__DIR__, "streams_client.exs"), "#{port}", "#{count}", body_file]
  ])
end

await_line = fn port, prefix ->
  receive do
    {^port, {:data, {:eol, ^prefix <> rest}}} -> rest
    {^port, {:exit_status, status}} -> raise "the stream client exited with #{status}"
  after
    120_000 -> raise "the stream client did not answer #{prefix}"
  end
end

kib = fn bytes -> :erlang.float_to_binary(bytes / 1024, decimals: 1) <> " KiB" end
ms = fn ns -> :erlang.float_to_binary(ns / 1.0e6, decimals: 2) <> " ms" end

IO.puts("# Open streams\n\n#{Bench.environment()}, #{rounds} broadcasts per count\n")

IO.puts(
  "| Streams | Memory per stream | Processes per stream | Broadcast to all, median | Broadcast to all, slowest |"
)

IO.puts("|---:|---:|---:|---:|---:|")

results =
  for count <- counts, into: %{} do
    {total0, _procs0, n0} = memory.()
    c = client.(count)
    _ = await_line.(c, "ready")

    # Every stream is registered once acknowledged, but give the last
    # handlers a moment to settle before measuring.
    Process.sleep(500)
    {total1, _procs1, n1} = memory.()
    per_stream = (total1 - total0) / count
    procs_per_stream = (n1 - n0) / count

    fanouts =
      for _ <- 1..rounds do
        Process.sleep(200)
        Port.command(c, "go\n")
        t0 = System.os_time(:nanosecond)
        :ok = Sake.Server.notify_list_changed(Bench.Server, :tools)
        received = c |> await_line.("received ") |> String.to_integer()
        received - t0
      end

    Port.command(c, "stop\n")

    receive do
      {^c, {:exit_status, _}} -> :ok
    after
      30_000 -> raise "the stream client did not stop"
    end

    # Let the server notice the closed connections.
    Process.sleep(1_000)

    sorted = Enum.sort(fanouts)
    median = Enum.at(sorted, div(length(sorted), 2))
    slowest = List.last(sorted)

    IO.puts(
      "| #{count} | #{kib.(per_stream)} | #{:erlang.float_to_binary(procs_per_stream, decimals: 1)} | #{ms.(median)} | #{ms.(slowest)} |"
    )

    {"streams / #{count} listen streams",
     %{
       "memory_bytes_per_stream" => per_stream,
       "processes_per_stream" => procs_per_stream,
       "broadcast_median_ns" => median,
       "broadcast_max_ns" => slowest
     }}
  end

File.rm(body_file)

if path = System.get_env("BENCH_JSON") do
  existing = with {:ok, body} <- File.read(path), do: JSON.decode!(body), else: (_ -> %{})
  File.write!(path, JSON.encode!(Map.merge(existing, results)))
end
