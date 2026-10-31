# HTTP throughput and latency: Sake behind Bandit, under load from oha
# (https://github.com/hatoo/oha), at fixed numbers of concurrent
# connections.
#
#     mix run bench/http.exs
#
# Needs `oha` on the PATH (`cargo install oha`, or a release binary).
#
# The load generator competes with the server for CPU. Run it on another
# machine (`BENCH_URL=http://server:4040/mcp`, with
# `BENCH_SERVER_ONLY=1 mix run bench/http.exs` on the server), or at
# least on other cores:
#
#     BENCH_LOAD_CPUS=2,3 taskset -c 0,1 elixir --erl "+S 2" -S mix run bench/http.exs
#
# Options (environment):
#
#   * `BENCH_CONCURRENCY` — connections, comma-separated (default 10,100,1000)
#   * `BENCH_DURATION` — seconds per run (default 15; 5 with BENCH_QUICK=1)
#   * `BENCH_PORT` — the port the server listens on (default 4040)
#   * `BENCH_LOAD_CPUS` — run oha under `taskset -c` on these CPUs
#   * `BENCH_JSON` — append the results to this JSON summary
#
# See guides/performance.md for how to read the numbers.

Code.require_file("support.exs", __DIR__)

quick? = System.get_env("BENCH_QUICK") in ["1", "true"]
port = String.to_integer(System.get_env("BENCH_PORT", "4040"))
duration = System.get_env("BENCH_DURATION", if(quick?, do: "5", else: "15"))

concurrency =
  System.get_env("BENCH_CONCURRENCY", "10,100,1000")
  |> String.split(",", trim: true)
  |> Enum.map(&String.to_integer(String.trim(&1)))

url =
  case System.get_env("BENCH_URL") do
    nil ->
      Bench.start_sake()

      {:ok, _} =
        Bandit.start_link(
          plug: {Sake.Plug, server: Bench.Server, secret: Bench.secret()},
          ip: :loopback,
          port: port,
          thousand_island_options: [num_connections: 20_000]
        )

      "http://127.0.0.1:#{port}/mcp"

    url ->
      url
  end

if System.get_env("BENCH_SERVER_ONLY") in ["1", "true"] do
  IO.puts("Serving #{url}; run the load from another machine with BENCH_URL=#{url}")
  Process.sleep(:infinity)
end

oha = System.find_executable("oha") || raise "bench/http.exs needs oha on the PATH"

# A legacy (2025-11-25) session for the session scenario.
init =
  Req.post!(url,
    headers: Bench.legacy_headers(nil),
    body:
      Bench.legacy_body(0, "initialize", %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "bench", "version" => "0"}
      }),
    decode_body: false
  )

[session] = Req.Response.get_header(init, "mcp-session-id")

Req.post!(url,
  headers: Bench.legacy_headers(session),
  body: JSON.encode!(Sake.JSONRPC.notification("notifications/initialized"))
)

echo = %{"name" => "echo", "arguments" => %{"text" => "hello"}}

scenarios = [
  {"tools/call echo (modern, JSON response)", Bench.modern_headers("tools/call", echo),
   Bench.modern_body(1, "tools/call", echo)},
  {"tools/call echo (modern, SSE response)", Bench.modern_headers("tools/call", echo),
   Bench.modern_body(1, "tools/call", Map.put(echo, "_meta", %{"progressToken" => "p1"}))},
  {"tools/call echo (2025-11-25 session)", Bench.legacy_headers(session),
   Bench.legacy_body(1, "tools/call", echo)}
]

load = fn headers, body, connections ->
  args =
    [
      "--no-tui",
      # Finish the requests in flight at the deadline instead of aborting them.
      "-w",
      "--output-format",
      "json",
      "-z",
      "#{duration}s",
      "-c",
      "#{connections}",
      "-m",
      "POST",
      "-d",
      body
    ] ++ Enum.flat_map(headers, fn {k, v} -> ["-H", "#{k}: #{v}"] end) ++ [url]

  {cmd, args} =
    case System.get_env("BENCH_LOAD_CPUS") do
      nil -> {oha, args}
      cpus -> {"taskset", ["-c", cpus, oha | args]}
    end

  {out, 0} = System.cmd(cmd, args)
  JSON.decode!(out)
end

IO.puts(
  "# HTTP throughput and latency\n\n#{Bench.environment()}, #{elem(System.cmd(oha, ["--version"]), 0) |> String.trim()}, #{duration}s per run\n"
)

IO.puts("| Scenario | Connections | Requests/s | p50 | p95 | p99 | Non-200 |")
IO.puts("|---|---:|---:|---:|---:|---:|---:|")

ms = fn seconds -> :erlang.float_to_binary(seconds * 1000, decimals: 2) <> " ms" end

results =
  for {name, headers, body} <- scenarios, connections <- concurrency, into: %{} do
    # A short warm-up at the same concurrency, not counted.
    _ = load.(headers, body, min(connections, 100))

    r = load.(headers, body, connections)
    p = r["latencyPercentiles"]
    codes = r["statusCodeDistribution"] || %{}
    ok = Map.get(codes, "200", 0)
    other = Enum.sum(Map.values(codes)) - ok
    rps = r["summary"]["requestsPerSec"]

    IO.puts(
      "| #{name} | #{connections} | #{round(rps)} | #{ms.(p["p50"])} | #{ms.(p["p95"])} | #{ms.(p["p99"])} | #{other} |"
    )

    {"http / #{name}, #{connections} connections",
     %{
       "rps" => rps,
       "p50_ns" => p["p50"] * 1.0e9,
       "p95_ns" => p["p95"] * 1.0e9,
       "p99_ns" => p["p99"] * 1.0e9,
       "non_200" => other
     }}
  end

if path = System.get_env("BENCH_JSON") do
  existing = with {:ok, body} <- File.read(path), do: JSON.decode!(body), else: (_ -> %{})
  File.write!(path, JSON.encode!(Map.merge(existing, results)))
end
