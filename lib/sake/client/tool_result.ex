defmodule Sake.Client.ToolResult do
  @moduledoc "The result of `Sake.Client.call_tool/3`."
  @type t :: %__MODULE__{}
  defstruct [:structured, content: [], is_error: false, text: "", meta: %{}]
end
