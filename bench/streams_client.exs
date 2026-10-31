# The client side of bench/streams.exs, run by it as a separate OS process
# so that the server's memory counts only the server. It opens `count`
# `subscriptions/listen` streams over raw TCP, spread over one process per
# scheduler, says `ready` once every stream is acknowledged, then, for
# each `go` line, reports when the last stream received the broadcast.
#
#     elixir bench/streams_client.exs PORT COUNT BODY_FILE
#
# Not meant to be run by hand.

defmodule Streams.Shard do
  # Holds a share of the streams and counts, per broadcast, the streams
  # that have received it. A stream's last bytes are kept so that a
  # marker split across two packets still counts.

  def start(parent, port, count, request) do
    spawn_link(fn ->
      sockets =
        for _ <- 1..count//1 do
          {:ok, socket} =
            :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: true, nodelay: true], 30_000)

          :ok = :gen_tcp.send(socket, request)
          socket
        end

      all = Map.new(sockets, &{&1, ""})
      _ = await("subscriptions/acknowledged", all, all, 0)
      send(parent, {:ready, self()})
      loop(parent, all)
    end)
  end

  defp loop(parent, all) do
    receive do
      :go ->
        last = await("tools/list_changed", all, all, 0)
        send(parent, {:received, self(), last})
        loop(parent, all)

      :stop ->
        Enum.each(Map.keys(all), &:gen_tcp.close/1)
    end
  end

  defp await(_marker, pending, _tails, last) when map_size(pending) == 0, do: last

  defp await(marker, pending, tails, last) do
    receive do
      {:tcp, socket, data} ->
        joined = Map.get(tails, socket, "") <> data
        size = byte_size(joined)
        tails = Map.put(tails, socket, binary_part(joined, max(size - 64, 0), min(size, 64)))

        if Map.has_key?(pending, socket) and String.contains?(joined, marker) do
          # The tail must not count this event again for the next one.
          await(
            marker,
            Map.delete(pending, socket),
            Map.put(tails, socket, ""),
            System.os_time(:nanosecond)
          )
        else
          await(marker, pending, tails, last)
        end

      {:tcp_closed, socket} ->
        raise "stream #{inspect(socket)} closed"
    after
      60_000 -> raise "timed out with #{map_size(pending)} streams waiting for #{marker}"
    end
  end
end

[port, count, body_file] = System.argv()
port = String.to_integer(port)
count = String.to_integer(count)
body = File.read!(body_file)

request =
  IO.iodata_to_binary([
    "POST /mcp HTTP/1.1\r\n",
    "host: 127.0.0.1:#{port}\r\n",
    "content-type: application/json\r\n",
    "accept: application/json, text/event-stream\r\n",
    "mcp-protocol-version: 2026-07-28\r\n",
    "mcp-method: subscriptions/listen\r\n",
    "content-length: #{byte_size(body)}\r\n",
    "\r\n",
    body
  ])

shard_count = min(System.schedulers_online(), count)

shards =
  for i <- 0..(shard_count - 1) do
    share = div(count, shard_count) + if(i < rem(count, shard_count), do: 1, else: 0)
    Streams.Shard.start(self(), port, share, request)
  end

for shard <- shards, do: receive(do: ({:ready, ^shard} -> :ok))
IO.puts("ready")

Enum.reduce_while(IO.stream(:stdio, :line), :ok, fn line, :ok ->
  case String.trim(line) do
    "go" ->
      Enum.each(shards, &send(&1, :go))
      last = shards |> Enum.map(fn s -> receive(do: ({:received, ^s, t} -> t)) end) |> Enum.max()
      IO.puts("received #{last}")
      {:cont, :ok}

    _ ->
      Enum.each(shards, &send(&1, :stop))
      {:halt, :ok}
  end
end)

Process.sleep(200)
