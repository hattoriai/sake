defmodule SakeTest.HTTP do
  @moduledoc false
  # A Bandit server around Sake.Plug on a random port, and an SSE collector.

  defmodule Router do
    @moduledoc false
    use Plug.Router
    plug :match
    plug :dispatch

    forward "/mcp",
      to: Sake.Plug,
      init_opts: [server: SakeDev.Server, secret: String.duplicate("s", 64)]

    match _, do: send_resp(conn, 404, "")
  end

  @doc "Starts Bandit under the test supervisor; returns the base URL."
  def start(plug \\ Router) do
    pid =
      ExUnit.Callbacks.start_supervised!(
        {Bandit,
         plug: plug,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false,
         thousand_island_options: [shutdown_timeout: 100]}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    "http://127.0.0.1:#{port}"
  end

  @doc """
  POSTs `body` with `headers` and collects SSE events until `until.(events)`
  is true or `timeout` ms pass. Returns `{status, headers, events}`.
  """
  def sse(url, body, headers, until, timeout \\ 5_000) do
    parent = self()

    task =
      Task.async(fn ->
        Req.post!(url,
          json: body,
          headers: headers,
          receive_timeout: timeout,
          into: fn {:data, data}, {req, resp} ->
            send(parent, {:sse_data, data})
            {:cont, {req, resp}}
          end
        )
      end)

    collect(task, "", [], until, timeout)
  end

  defp collect(task, buffer, events, until, timeout) do
    receive do
      {:sse_data, data} ->
        {events2, rest} = parse(buffer <> data, events)

        if until.(events2) do
          Task.shutdown(task, :brutal_kill)
          {:ok, events2}
        else
          collect(task, rest, events2, until, timeout)
        end

      {ref, %Req.Response{} = resp} when ref == task.ref ->
        {:done, resp.status, events}
    after
      timeout ->
        Task.shutdown(task, :brutal_kill)
        {:timeout, events}
    end
  end

  defp parse(buffer, events) do
    case String.split(buffer, "\n\n") do
      [rest] ->
        {events, rest}

      blocks ->
        {complete, [rest]} = Enum.split(blocks, -1)
        {events ++ Enum.flat_map(complete, &decode_block/1), rest}
    end
  end

  defp decode_block(block) do
    data =
      block
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data: "))
      |> Enum.map_join("\n", &String.replace_prefix(&1, "data: ", ""))

    if data == "", do: [], else: [JSON.decode!(data)]
  end
end
