defmodule Sake.Input do
  @moduledoc """
  Asks the client several things at once.

      [name, roots] =
        Sake.Input.all(ctx, [
          &Sake.Elicit.form(&1, :name, "Who are you?", schema),
          &Sake.Roots.list(&1, :roots)
        ])

  Each function is one `Sake.Elicit`, `Sake.Sampling` or `Sake.Roots`
  call; `all/2` returns their results in the same order. Called one after
  the other, those functions would ask one question per round-trip on a
  modern connection; under `all/2` every unanswered question goes out in
  the same input-required result. On a legacy connection they are asked
  in turn on the stream.
  """

  alias Sake.Context

  @spec all(Context.t(), [(Context.t() -> term())]) :: [term()]
  # Each function runs until its first unanswered request; the requests of
  # all of them unwind together, as one input-required result.
  def all(%Context{era: :modern} = ctx, funs) do
    {results, pending} =
      Enum.map_reduce(funs, %{}, fn fun, pending ->
        try do
          {fun.(ctx), pending}
        catch
          :throw, {:sake_input_required, requests} -> {nil, Map.merge(pending, requests)}
        end
      end)

    if pending == %{}, do: results, else: throw({:sake_input_required, pending})
  end

  def all(ctx, funs), do: Enum.map(funs, & &1.(ctx))
end
