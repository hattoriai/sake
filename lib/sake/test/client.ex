defmodule Sake.Test.Client do
  @moduledoc """
  A client of `Sake.Test`, from `Sake.Test.connect/2`.

  It names the process that keeps the client's `Sake.Client.Session`
  between calls, so a test need not thread the session through; the
  process is linked to the one that connected, and ends with it.
  `Sake.Test.session/1` returns the session, for `Sake.Client` itself.
  """

  @type t :: %__MODULE__{pid: pid(), server: module()}
  defstruct [:pid, :server]
end
