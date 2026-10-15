defmodule SakeDev.Tools.Export do
  @moduledoc false
  # A task: asks for a format, reports progress as its status message, and
  # stops early when the client cancels.
  use Sake.Tool, name: "export", description: "Exports the issues, as a task", task: :optional
  arg :n, :integer, default: 3, min: 1, max: 100
  arg :delay_ms, :integer, default: 10, min: 0, max: 1000

  @impl true
  def execute(%{n: n, delay_ms: delay}, ctx) do
    case Sake.Elicit.form(ctx, :format, "Which format?", %{
           "type" => "object",
           "properties" => %{"format" => %{"type" => "string", "enum" => ["csv", "json"]}},
           "required" => ["format"]
         }) do
      {:ok, %{"format" => format}} -> export(n, delay, format, ctx)
      _ -> {:error, "No format, no export."}
    end
  end

  defp export(n, delay, format, ctx) do
    exported =
      Enum.reduce_while(1..n, 0, fn i, done ->
        if Sake.Tasks.cancelled?(ctx) do
          {:halt, done}
        else
          Process.sleep(delay)
          Sake.Progress.report(ctx, i, n, "Exported #{i} of #{n}")
          {:cont, i}
        end
      end)

    {:ok, "Exported #{exported} issues as #{format}."}
  end
end
