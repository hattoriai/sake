# Performance

What Sake costs per request, how many requests one server answers, what
an open stream costs, and what each way of authorizing adds. Every
number on this page comes from the scripts in `bench/`, so you can
rerun them on your own hardware.

Every tool in the benchmarks is close to a no-op (an `echo`), so the
numbers measure Sake: decoding, the protocol headers, argument
validation, dispatch, the result, encoding and the transport. A tool
that queries a database or calls an API adds its own time on top.

## The results

Measured on a 4-vCPU cloud VM (Intel Xeon @ 2.80GHz, 16 GB), Linux,
Elixir 1.20.1 on OTP 29, Sake 0.4.4, Bandit 1.13.0. A shared VM is a
noisy place to measure: take the numbers as orders of magnitude, and
rerun them on your own hardware for anything finer.

### Per call, in process

`mix run bench/dispatch.exs`. One request through `Sake.Plug`'s `call/2`,
the code a request from Bandit or Phoenix runs after the socket. The
median is of thousands of calls, each in a fresh process (see
"How the measurements are made"). Memory is what
one call allocates.

| Request | Median | p99 | Memory |
|---|---:|---:|---:|
| `tools/call` echo, modern (2026-07-28) | 70 µs | 211 µs | 25 KiB |
| `tools/call` echo, a 2025-11-25 session | 75 µs | 214 µs | 23 KiB |
| `tools/call` echo, modern, SSE response | 121 µs | 321 µs | 26 KiB¹ |
| `tools/call` with 20 arguments (enums, bounds, arrays, a nested object) | 141 µs | 343 µs | 52 KiB |
| `tools/list`, 10 tools | 92 µs | 239 µs | 52 KiB |
| `tools/list`, 100 tools | 462 µs | 1.2 ms | 329 KiB |
| `Sake.Test` round trip, echo (client and server) | 107 µs | 306 µs | 23 KiB |

Starting the fresh process itself costs 3 µs (the `baseline` scenario).

¹ Not counting the handler task an SSE response runs the tool in.

### Over HTTP

`mix run bench/http.exs`. Bandit and Sake pinned to two cores
(`taskset -c 0,1`, `+S 2`), and oha, the load generator, to the other
two. Each run lasts 15 seconds over keep-alive connections. No request
failed.

| Request | Connections | Requests/s | p50 | p95 | p99 |
|---|---:|---:|---:|---:|---:|
| `tools/call` echo, modern, JSON response | 10 | 8,513 | 1.1 ms | 1.9 ms | 2.3 ms |
| | 100 | 7,983 | 11.6 ms | 17.9 ms | 23.3 ms |
| | 1,000 | 7,616 | 123 ms | 177 ms | 191 ms |
| `tools/call` echo, modern, SSE response | 10 | 5,831 | 1.6 ms | 2.6 ms | 3.5 ms |
| | 100 | 6,293 | 15.2 ms | 21.4 ms | 25.2 ms |
| | 1,000 | 5,379 | 179 ms | 239 ms | 273 ms |
| `tools/call` echo, a 2025-11-25 session | 10 | 7,941 | 1.2 ms | 2.0 ms | 2.3 ms |
| | 100 | 7,568 | 11.7 ms | 19.6 ms | 22.1 ms |
| | 1,000 | 7,354 | 130 ms | 177 ms | 197 ms |

The two server cores are saturated from 10 connections on. Past that
point more connections only queue: throughput stays the same, and
latency grows with the queue. On more cores, throughput grows with
them: requests are independent processes.

### Open streams

`mix run bench/streams.exs`. `subscriptions/listen` streams opened by a
separate OS process. Memory is the server's (the whole VM), per open
stream. A broadcast is one `Sake.Server.notify_list_changed/2`, timed
until the last stream has received it.

| Open streams | Memory per stream | Broadcast to all, median | Broadcast to all, slowest of 5 |
|---:|---:|---:|---:|
| 1,000 | 27 KiB | 21 ms | 26 ms |
| 5,000 | 22 KiB | 111 ms | 238 ms |
| 9,000 | 18 KiB | 349 ms | 491 ms |

Each stream is one process. 10,000 open streams take about 200 MB.

### Authorization

`mix run bench/auth.exs`, with `DATABASE_URL` for the Ecto store. The
same `tools/call` echo, in process, as in the per-call table above.

| Token | Median | p99 | Added to the call |
|---|---:|---:|---:|
| None | 71 µs | 197 µs | — |
| `Sake.Auth` bearer, ETS store | 122 µs | 344 µs | +51 µs |
| `Sake.Auth` bearer, Ecto store (Postgres on the same machine) | 625 µs | 1.2 ms | +554 µs |
| `Sake.Auth` DPoP-bound, a proof checked per request, ETS store | 478 µs | 904 µs | +407 µs |
| `Sake.Auth` DPoP-bound, Ecto store (Postgres on the same machine) | 2.5 ms | 4.6 ms | +2.4 ms |
| `Sake.Auth.External`, a JWT (ES256) | 327 µs | 628 µs | +256 µs |
| `Sake.Auth.External`, introspection, cached (the default) | 103 µs | 275 µs | +32 µs |
| `Sake.Auth.External`, introspection on every request (`cache: 0`, a local server) | 693 µs | 1.4 ms | +622 µs |
| `Sake.Auth.External`, your callback | 126 µs | 297 µs | +55 µs |

The DPoP proofs are signed before the measurement, since signing is the
client's cost. Checking a signature (DPoP, and External JWTs) is most of
what those rows add.

## Reading the numbers

- **A tool call costs Sake about 70 µs of CPU.** At that cost one core
  answers about 4,000 calls a second over HTTP, before your tool does
  anything. Most tools spend far longer in their own work, a database
  query or an API call, than Sake spends around them.
- **`tools/list` grows with the tools a server has**, since every tool's
  schema is encoded on every list: about 4 µs and 3 KiB per tool.
- **An SSE response costs about 50 µs more than JSON.** Sake answers with
  SSE only when it has to: when the client asked for progress, the tool
  streams (`stream: true`), or a legacy client can be asked something.
- **The Ecto token store makes every authorized request a database
  round trip.** It reads the token, and with DPoP also writes the
  proof's replay record. It is what makes tokens survive restarts and
  work on several nodes (see `guides/clustering.md`). On one node, the
  ETS store is about 10 times cheaper.
- **Introspection is cheap only cached.** The default 60-second cache
  makes it the cheapest external option. `cache: 0` pays an HTTP round
  trip on every request, and more than this table shows when the
  authorization server is across a network.

## Running them

```bash
mix run bench/dispatch.exs
```

```bash
DATABASE_URL=ecto://postgres:postgres@localhost/sake_bench mix run bench/auth.exs
```

```bash
BENCH_LOAD_CPUS=2,3 taskset -c 0,1 elixir --erl "+S 2" -S mix run bench/http.exs
```

```bash
ulimit -n 20000 && mix run bench/streams.exs
```

`bench/http.exs` needs [oha](https://github.com/hatoo/oha) on the
`PATH`. It is best run with the load on another machine: there,
`BENCH_SERVER_ONLY=1 mix run bench/http.exs` serves, and
`BENCH_URL=http://server:4040/mcp mix run bench/http.exs` loads.

Each script's header lists its options. They share:

- `BENCH_QUICK=1` shortens every run.
- `BENCH_JSON=path` appends the results to a JSON summary.

## Comparing two versions

To see what a change costs, run the per-call benchmark on both versions
on the same machine, a few times each and in turn. A busy moment on
the machine then falls on both. `bench/compare.exs` compares the fastest
median of each side's runs. Both versions need `bench/` and the
`benchee` dependency, so this works from the version that added them.

```bash
git worktree add ../sake-main main
```

```bash
for i in 1 2 3; do
  (cd ../sake-main && BENCH_JSON=/tmp/main-$i.json mix run bench/dispatch.exs)
  BENCH_JSON=/tmp/branch-$i.json mix run bench/dispatch.exs
done
```

```bash
elixir bench/compare.exs /tmp/main-1.json,/tmp/main-2.json,/tmp/main-3.json /tmp/branch-1.json,/tmp/branch-2.json,/tmp/branch-3.json
```

On a shared VM, two runs of the same code differ by up to 25%. A change
smaller than that needs quieter hardware, or more runs, to show.

## How the measurements are made

- **Each call runs in a fresh process.** Bandit runs each connection in
  a process of its own, with a small heap. A call run in Benchee's own
  process pays for collecting that process's heap, which grows with the
  samples Benchee keeps, and measures more than twice slower than it
  runs in production.
- **Memory is measured separately**, in the calling process, as Benchee
  only can.
- **The load generator runs apart from the server**: on other cores here,
  or on another machine. On the same cores it would take CPU from the
  server it measures.
- **The streams' client is a separate OS process**, so the server's
  memory counts only the server. Broadcast times are measured against
  the OS clock both processes share.
- **Every scenario is checked once before it is measured**: a request
  that fails would otherwise be timed as a fast one.
- **Each result is the median of a run**, after a warm-up. Rerun anything
  you want to rely on.

Not measured yet: several nodes with `pubsub:`, and the same benchmarks
against other MCP SDKs.
