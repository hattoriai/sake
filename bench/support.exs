# Shared by the benchmark scripts: the servers they measure, requests
# built the way a client sends them, and the JSON summary bench/compare.exs reads.
#
# Every tool is close to a no-op, so a benchmark measures Sake (decoding,
# validation, dispatch, encoding, transport) and not the tool.

defmodule Bench.Echo do
  use Sake.Tool, name: "echo", description: "Returns the text it receives"
  arg :text, :string, required: true

  @impl true
  def execute(%{text: text}, _ctx), do: {:ok, text}
end

defmodule Bench.Wide do
  # A tool with a schema of the size a real API tool has: twenty
  # arguments, enums, bounds, a pattern, arrays and a nested object.
  use Sake.Tool, name: "search_orders", description: "Search orders"

  arg :query, :string, required: true, min_length: 1, max_length: 200
  arg :status, {:enum, ["open", "paid", "shipped", "cancelled"]}
  arg :customer_id, :string, pattern: "^cus_[a-zA-Z0-9]+$"
  arg :min_total, :number, min: 0
  arg :max_total, :number, min: 0
  arg :currency, {:enum, ["usd", "eur", "gbp", "jpy"]}
  arg :page, :integer, min: 1, default: 1
  arg :per_page, :integer, min: 1, max: 100, default: 25
  arg :tags, {:array, :string}
  arg :ids, {:array, :integer}
  arg :include_items, :boolean
  arg :include_customer, :boolean
  arg :sort, {:enum, ["created", "updated", "total"]}
  arg :order, {:enum, ["asc", "desc"]}
  arg :created_after, :string, format: "date-time"
  arg :created_before, :string, format: "date-time"
  arg :country, :string, min_length: 2, max_length: 2
  arg :channel, {:enum, ["web", "pos", "api"]}
  arg :note, :string, max_length: 500

  arg :shipping,
      {:object,
       [
         {:carrier, {:enum, ["ups", "fedex", "dhl"]}, []},
         {:express, :boolean, []},
         {:max_days, :integer, [min: 1]}
       ]}

  @impl true
  def execute(_args, _ctx), do: {:ok, "0 orders"}

  def arguments do
    %{
      "query" => "blue shoes",
      "status" => "paid",
      "customer_id" => "cus_9fK2a",
      "min_total" => 10,
      "max_total" => 250.5,
      "currency" => "eur",
      "page" => 2,
      "per_page" => 50,
      "tags" => ["gift", "priority", "returning"],
      "ids" => [101, 102, 103, 104],
      "include_items" => true,
      "include_customer" => false,
      "sort" => "total",
      "order" => "desc",
      "created_after" => "2026-01-01T00:00:00Z",
      "created_before" => "2026-10-01T00:00:00Z",
      "country" => "PT",
      "channel" => "web",
      "note" => "only orders with a tracking number",
      "shipping" => %{"carrier" => "dhl", "express" => true, "max_days" => 3}
    }
  end
end

defmodule Bench.Tools do
  @moduledoc false
  # `count` echo-like tools, as modules named Bench.Tools.T1..Tn.
  def define(count) do
    for i <- 1..count do
      name = Module.concat(__MODULE__, "T#{i}")

      unless Code.ensure_loaded?(name) do
        Module.create(
          name,
          quote do
            use Sake.Tool,
              name: unquote("tool_#{i}"),
              description: unquote("Tool number #{i}, which returns the text it receives")

            arg :text, :string, required: true, description: "The text to return"
            arg :limit, :integer, min: 1, max: 100

            @impl true
            def execute(%{text: text}, _ctx), do: {:ok, text}
          end,
          Macro.Env.location(__ENV__)
        )
      end

      name
    end
  end
end

defmodule Bench.Server do
  use Sake.Server, name: "bench", version: "1.0.0"
  tools [Bench.Echo, Bench.Wide]
end

Bench.Tools.define(100)

defmodule Bench.Server10 do
  use Sake.Server, name: "bench-10", version: "1.0.0"
  tools(for i <- 1..10, do: Module.concat(Bench.Tools, "T#{i}"))
end

defmodule Bench.Server100 do
  use Sake.Server, name: "bench-100", version: "1.0.0"
  tools(for i <- 1..100, do: Module.concat(Bench.Tools, "T#{i}"))
end

defmodule Bench do
  @moduledoc false
  import Plug.Conn

  @secret String.duplicate("b", 64)
  @modern "2026-07-28"
  @legacy "2025-11-25"

  def secret, do: @secret

  @doc "Starts what Sake needs (the stream registry and tasks), plus `extra` options."
  def start_sake(extra \\ []) do
    {:ok, _} =
      Supervisor.start_link([{Sake, Keyword.merge([secret_key_base: @secret], extra)}],
        strategy: :one_for_one
      )

    :ok
  end

  def plug(server, opts \\ []),
    do: Sake.Plug.init(Keyword.merge([server: server, secret: @secret], opts))

  @doc "The JSON body of a modern (2026-07-28) request, with its per-request `_meta`."
  def modern_body(id, method, params \\ %{}) do
    meta = %{
      "io.modelcontextprotocol/protocolVersion" => @modern,
      "io.modelcontextprotocol/clientCapabilities" => %{},
      "io.modelcontextprotocol/clientInfo" => %{"name" => "bench", "version" => "0"}
    }

    JSON.encode!(
      Sake.JSONRPC.request(id, method, Map.update(params, "_meta", meta, &Map.merge(meta, &1)))
    )
  end

  @doc "The headers a modern client sends with `method` (and the tool name)."
  def modern_headers(method, params \\ %{}) do
    [
      {"content-type", "application/json"},
      {"accept", "application/json, text/event-stream"},
      {"mcp-protocol-version", @modern},
      {"mcp-method", method}
    ] ++ if(params["name"], do: [{"mcp-name", params["name"]}], else: [])
  end

  @doc "A modern request as a `Plug.Test` conn."
  def modern_conn(method, params \\ %{}, headers \\ [], path \\ "/mcp") do
    conn(:post, modern_body(1, method, params), modern_headers(method, params) ++ headers, path)
  end

  def legacy_body(id, method, params \\ %{}),
    do: JSON.encode!(Sake.JSONRPC.request(id, method, params))

  def legacy_headers(session_id) do
    [
      {"content-type", "application/json"},
      {"accept", "application/json, text/event-stream"},
      {"mcp-protocol-version", @legacy}
    ] ++ if(session_id, do: [{"mcp-session-id", session_id}], else: [])
  end

  @doc "Opens a legacy (#{@legacy}) session through `plug_opts`; returns its ID."
  def legacy_session(plug_opts) do
    init =
      Sake.JSONRPC.request(0, "initialize", %{
        "protocolVersion" => @legacy,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "bench", "version" => "0"}
      })

    conn = Sake.Plug.call(conn(:post, JSON.encode!(init), legacy_headers(nil)), plug_opts)
    200 = conn.status
    [session] = get_resp_header(conn, "mcp-session-id")

    initialized = JSON.encode!(Sake.JSONRPC.notification("notifications/initialized"))
    _ = Sake.Plug.call(conn(:post, initialized, legacy_headers(session)), plug_opts)
    session
  end

  def legacy_conn(session, method, params \\ %{}),
    do: conn(:post, legacy_body(1, method, params), legacy_headers(session))

  defp conn(method, body, headers, path \\ "/mcp") do
    Enum.reduce(headers, Plug.Test.conn(method, path, body), fn {k, v}, conn ->
      put_req_header(conn, k, v)
    end)
  end

  @doc "Runs `conn` through the plug and checks it answered 200 with no JSON-RPC error."
  def call!(conn, plug_opts) do
    conn = Sake.Plug.call(conn, plug_opts)

    if conn.status != 200 or String.contains?(conn.resp_body, ~s("error":)) do
      raise "unexpected response #{conn.status}: #{String.slice(conn.resp_body, 0, 300)} " <>
              inspect(get_resp_header(conn, "www-authenticate"))
    end

    conn
  end

  @doc "Runs every scenario once, naming the one that fails."
  def check!(scenarios) do
    Enum.each(scenarios, fn {name, fun} ->
      try do
        fun.()
      rescue
        e -> reraise RuntimeError, [message: "#{name}: #{Exception.message(e)}"], __STACKTRACE__
      end
    end)
  end

  @baseline "baseline: a fresh process, no request"

  @doc """
  Measures `scenarios` (a map of name to function), in two passes.

  Time: every call runs in a fresh process, as Bandit runs each request in
  a process of its own. Run in the benchmark's own process, a call would
  pay for garbage-collecting that process's heap, which grows with the
  samples Benchee keeps, and measure more than twice slower than it runs
  in production. The `#{@baseline}` scenario is what the fresh process
  itself costs.

  Memory: what one call allocates, measured in the calling process (Benchee
  can only measure there). Work a request hands to another process (the
  handler task of an SSE response) is not counted.

  Shortened by `BENCH_QUICK=1`. Appends the medians to the JSON
  summary at `BENCH_JSON` when set.
  """
  def run(title, scenarios) do
    quick? = System.get_env("BENCH_QUICK") in ["1", "true"]

    isolated =
      scenarios
      |> Map.new(fn {name, fun} -> {name, fn -> isolated(fun) end} end)
      |> Map.put(@baseline, fn -> isolated(fn -> :ok end) end)

    time =
      Benchee.run(isolated,
        title: title,
        warmup: if(quick?, do: 1, else: 2),
        time: if(quick?, do: 3, else: 5),
        memory_time: 0,
        print: [fast_warning: false, configuration: false]
      )

    memory =
      Benchee.run(scenarios,
        title: title <> " (memory)",
        warmup: 0,
        time: 0,
        memory_time: 1,
        print: [benchmarking: false, configuration: false]
      )

    summarize(title, time, memory)
  end

  defp isolated(fun) do
    fun |> Task.async() |> Task.await(:infinity)
  end

  defp summarize(title, time, memory) do
    case System.get_env("BENCH_JSON") do
      nil ->
        :ok

      path ->
        existing =
          case File.read(path) do
            {:ok, body} -> JSON.decode!(body)
            _ -> %{}
          end

        allocated =
          Map.new(memory.scenarios, &{&1.name, &1.memory_usage_data.statistics.median})

        results =
          Map.new(time.scenarios, fn s ->
            run = s.run_time_data.statistics

            {"#{title} / #{s.name}",
             %{
               "median_ns" => run.median,
               "p99_ns" => run.percentiles[99],
               "ips" => run.ips,
               "memory_bytes" => allocated[s.name]
             }}
          end)

        File.write!(path, JSON.encode!(Map.merge(existing, results)))
    end
  end

  @doc "The machine and versions a result came from."
  def environment do
    {os_family, os_name} = :os.type()

    """
    Elixir #{System.version()}, OTP #{System.otp_release()} (ERTS #{:erlang.system_info(:version)}), \
    #{os_family}/#{os_name}, #{System.schedulers_online()} schedulers, \
    Sake #{Application.spec(:sake, :vsn)} at #{commit()}\
    """
  end

  defp commit do
    case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> "unknown"
    end
  end
end
