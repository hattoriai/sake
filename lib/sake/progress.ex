defmodule Sake.Progress do
  @moduledoc """
  Progress and log notifications from inside a component.

      Sake.Progress.report(ctx, 3, 10)
      Sake.Progress.report(ctx, 3, 10, "Indexing")
      Sake.Progress.log(ctx, :info, %{"step" => "index"})

  Progress goes out only when the request carried a progress token; log
  messages only when the request set a log level at or below `level`.
  """

  @levels ~w(debug info notice warning error critical alert emergency)a

  @spec report(Sake.Context.t(), number(), number() | nil, String.t() | nil) :: :ok
  def report(%Sake.Context{progress: fun}, current, total \\ nil, message \\ nil)
      when is_function(fun, 2) do
    fun.(current, {total, message})
    :ok
  end

  @names Enum.map(@levels, &Atom.to_string/1)

  @spec log(Sake.Context.t(), atom(), term()) :: :ok
  def log(%Sake.Context{log_level: nil}, _level, _data), do: :ok

  def log(%Sake.Context{log_level: min, transport: pid}, level, data)
      when level in @levels and is_pid(pid) and min in @names do
    if index(Atom.to_string(level)) >= index(min),
      do: send(pid, {:sake_log, level, data})

    :ok
  end

  def log(_ctx, _level, _data), do: :ok

  @doc false
  # Whether a client-sent level is one of the eight syslog levels MCP uses.
  @spec level?(term()) :: boolean()
  def level?(level), do: level in @names

  defp index(name), do: Enum.find_index(@names, &(&1 == name))
end
