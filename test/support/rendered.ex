defmodule SakeTest.Rendered do
  @moduledoc false
  # Stands for a HEEx component's `%Phoenix.LiveView.Rendered{}`: a struct
  # that Phoenix.HTML turns into HTML. Its implementation lives here, not in
  # a test, so that it is part of the consolidated protocol.
  defstruct [:html]

  defimpl Phoenix.HTML.Safe do
    def to_iodata(%{html: html}), do: ["<section>", html, "</section>"]
  end
end
