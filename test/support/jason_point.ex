defmodule SakeTest.JasonPoint do
  @moduledoc false
  # A struct as many Phoenix applications have them: it derives
  # `Jason.Encoder` and not `JSON.Encoder`. It lives here rather than in
  # a test file so that the consolidated protocol includes it.
  @derive Jason.Encoder
  defstruct [:x, :y]
end
