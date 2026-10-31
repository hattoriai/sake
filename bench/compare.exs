# Compares JSON summaries of bench/dispatch.exs (`BENCH_JSON`), for
# instance `main`'s and your branch's, and reports each scenario's change
# in median time. See "Comparing two versions" in guides/performance.md.
#
#     elixir bench/compare.exs main.json branch.json
#     elixir bench/compare.exs main-1.json,main-2.json branch-1.json,branch-2.json
#
# With several runs a side (comma-separated), each scenario's fastest
# median is compared: the time a call needs, without the noise of a busy
# moment on the machine. A change under `BENCH_THRESHOLD` (a ratio,
# default 1.10: 10%) is marked as noise.

# The fastest median of each scenario over a side's runs, and the memory
# of that run.
load = fn paths ->
  paths
  |> String.split(",", trim: true)
  |> Enum.map(&(&1 |> File.read!() |> JSON.decode!()))
  |> Enum.reduce(%{}, fn run, acc ->
    Map.merge(acc, run, fn _name, a, b -> if b["median_ns"] < a["median_ns"], do: b, else: a end)
  end)
end

[base_paths, head_paths] = System.argv()
base = load.(base_paths)
head = load.(head_paths)
threshold = String.to_float(System.get_env("BENCH_THRESHOLD", "1.10"))

us = fn ns -> :erlang.float_to_binary(ns / 1000, decimals: 1) <> " µs" end

kib = fn
  nil -> "–"
  bytes -> :erlang.float_to_binary(bytes / 1024, decimals: 1) <> " KiB"
end

IO.puts("| Scenario | Before | After | Change | Memory before | Memory after |")
IO.puts("|---|---:|---:|---:|---:|---:|")

for {name, h} <- Enum.sort(head),
    b = base[name],
    b != nil,
    not String.contains?(name, "baseline:") do
  ratio = h["median_ns"] / b["median_ns"]
  change = :erlang.float_to_binary((ratio - 1) * 100, decimals: 1)
  sign = if ratio >= 1, do: "+", else: ""

  verdict =
    cond do
      ratio > threshold -> " (slower)"
      ratio < 1 / threshold -> " (faster)"
      true -> " (noise)"
    end

  IO.puts(
    "| #{name} | #{us.(b["median_ns"])} | #{us.(h["median_ns"])} | #{sign}#{change}%#{verdict} | #{kib.(b["memory_bytes"])} | #{kib.(h["memory_bytes"])} |"
  )
end
