defmodule Sake.UI.Engine do
  @moduledoc false
  # The EEx engine of a `Sake.UI` template: `@name` reads an assign, and
  # `<%= %>` escapes its output as HTML unless the value is `{:safe,
  # iodata}` (`Sake.UI.raw/1`). The body of a block (`<%= for ... do %>`)
  # is template output already, so it comes back marked safe and is not
  # escaped a second time. The code it generates calls only Sake.

  @behaviour EEx.Engine

  @impl true
  defdelegate init(opts), to: EEx.Engine

  @impl true
  defdelegate handle_body(state), to: EEx.Engine

  @impl true
  defdelegate handle_begin(state), to: EEx.Engine

  @impl true
  def handle_end(state), do: {:safe, EEx.Engine.handle_end(state)}

  @impl true
  defdelegate handle_text(state, meta, text), to: EEx.Engine

  @impl true
  def handle_expr(state, "=", expr) do
    expr = Macro.prewalk(expr, &assign/1)
    EEx.Engine.handle_expr(state, "=", quote(do: Sake.UI.escape(unquote(expr))))
  end

  def handle_expr(state, marker, expr),
    do: EEx.Engine.handle_expr(state, marker, Macro.prewalk(expr, &assign/1))

  defp assign({:@, meta, [{name, _, atom}]}) when is_atom(name) and is_atom(atom) do
    line = meta[:line] || 0
    quote(line: line, do: Sake.UI.fetch_assign!(var!(assigns), unquote(name)))
  end

  defp assign(expr), do: expr
end
