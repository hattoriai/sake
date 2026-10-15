defmodule SakeTest.Pipe do
  @moduledoc false
  # An in-memory IO device for driving `Sake.Stdio` in place of standard
  # input and output: what the test pushes is read as input lines, and
  # every line written to it reaches the test as `{:pipe, pipe, message}`,
  # decoded from JSON.

  def start(owner \\ self()),
    do:
      spawn_link(fn -> loop(%{owner: owner, lines: [], waiting: nil, closed: false, out: ""}) end)

  @doc "Writes one input line: a message encoded as JSON, or a raw line as given."
  def push(pipe, line) when is_binary(line), do: send(pipe, {:push, line <> "\n"})
  def push(pipe, message), do: push(pipe, JSON.encode!(message))

  @doc "Ends the input: the next read returns `:eof`."
  def close(pipe), do: send(pipe, :close)

  defp loop(state) do
    receive do
      {:push, line} ->
        state |> Map.update!(:lines, &(&1 ++ [line])) |> answer() |> loop()

      :close ->
        %{state | closed: true} |> answer() |> loop()

      {:io_request, from, reply_as, request} ->
        state |> io(from, reply_as, request) |> loop()
    end
  end

  defp io(state, from, reply_as, {:get_line, _encoding, _prompt}),
    do: answer(%{state | waiting: {from, reply_as}})

  defp io(state, from, reply_as, {:put_chars, _encoding, chars}) do
    {lines, rest} = split(state.out <> IO.chardata_to_string(chars))
    for line <- lines, do: send(state.owner, {:pipe, self(), JSON.decode!(line)})
    send(from, {:io_reply, reply_as, :ok})
    %{state | out: rest}
  end

  defp io(state, from, reply_as, {:put_chars, encoding, m, f, a}),
    do: io(state, from, reply_as, {:put_chars, encoding, apply(m, f, a)})

  defp io(state, from, reply_as, {:setopts, _opts}) do
    send(from, {:io_reply, reply_as, :ok})
    state
  end

  defp io(state, from, reply_as, _request) do
    send(from, {:io_reply, reply_as, {:error, :request}})
    state
  end

  defp answer(%{waiting: nil} = state), do: state

  defp answer(%{waiting: {from, reply_as}, lines: [line | lines]} = state) do
    send(from, {:io_reply, reply_as, line})
    %{state | waiting: nil, lines: lines}
  end

  defp answer(%{waiting: {from, reply_as}, lines: [], closed: true} = state) do
    send(from, {:io_reply, reply_as, :eof})
    %{state | waiting: nil}
  end

  defp answer(state), do: state

  defp split(out) do
    parts = String.split(out, "\n")
    {Enum.drop(parts, -1), List.last(parts)}
  end
end
