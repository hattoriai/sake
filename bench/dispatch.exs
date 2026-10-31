# Per-call overhead, in process: what Sake costs for one request, without
# a network or a load generator in the way.
#
#     mix run bench/dispatch.exs
#
# Each scenario runs a `Plug.Test` request through `Sake.Plug.call/2` (the
# same code path a request from Bandit or Phoenix takes after the socket):
# JSON decoding, the protocol headers, argument validation, dispatch, the
# result and its encoding. `Sake.Test` adds the client side too.
#
# See guides/performance.md for how to read the numbers.

Code.require_file("support.exs", __DIR__)

Bench.start_sake()

echo = %{"name" => "echo", "arguments" => %{"text" => "hello"}}
wide = %{"name" => "search_orders", "arguments" => Bench.Wide.arguments()}

plug = Bench.plug(Bench.Server)
plug10 = Bench.plug(Bench.Server10)
plug100 = Bench.plug(Bench.Server100)
session = Bench.legacy_session(plug)
client = Sake.Test.connect(Bench.Server)

# Every scenario is checked once before it is measured.
progress = put_in(echo, ["_meta"], %{"progressToken" => "p1"})
sse = Bench.call!(Bench.modern_conn("tools/call", progress), plug)
true = sse.state == :chunked or String.contains?(sse.resp_body, "data:")
{:ok, %{text: "hello"}} = Sake.Test.call_tool(client, "echo", %{"text" => "hello"})

IO.puts("# Per-call overhead\n\n#{Bench.environment()}\n")

Bench.run(
  "dispatch",
  %{
    "tools/call echo (modern)" => fn ->
      Bench.call!(Bench.modern_conn("tools/call", echo), plug)
    end,
    "tools/call echo (modern, SSE response)" => fn ->
      Bench.call!(Bench.modern_conn("tools/call", progress), plug)
    end,
    "tools/call echo (2025-11-25 session)" => fn ->
      Bench.call!(Bench.legacy_conn(session, "tools/call", echo), plug)
    end,
    "tools/call with 20 arguments (modern)" => fn ->
      Bench.call!(Bench.modern_conn("tools/call", wide), plug)
    end,
    "tools/list, 10 tools (modern)" => fn ->
      Bench.call!(Bench.modern_conn("tools/list"), plug10)
    end,
    "tools/list, 100 tools (modern)" => fn ->
      Bench.call!(Bench.modern_conn("tools/list"), plug100)
    end,
    "Sake.Test round trip, echo (client + server)" => fn ->
      {:ok, _} = Sake.Test.call_tool(client, "echo", %{"text" => "hello"})
    end
  }
)
