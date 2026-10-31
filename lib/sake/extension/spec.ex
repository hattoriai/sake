defmodule Sake.Extension.Spec do
  @moduledoc """
  The compiled definition of a `Sake.Extension`: its identifier, its
  methods (`Sake.Extension.Method`), the notifications it sends, and its
  negotiation options. `mount` is the chain of servers between the server
  that lists it and the one that serves it, innermost first, as
  `{server, opts}`; `[]` for its own.
  """
  @type t :: %__MODULE__{}

  defstruct [
    :id,
    :module,
    :since,
    methods: [],
    notifications: [],
    client: :optional,
    result_types: [],
    mount: []
  ]
end

defmodule Sake.Extension.Method do
  @moduledoc """
  One method of a `Sake.Extension`: its name, the extension's module and
  identifier, and the scopes and authentication a call needs, checked as
  a tool's are.
  """
  @type t :: %__MODULE__{}

  defstruct [:name, :module, :id, scopes: [], authentication: nil]
end
