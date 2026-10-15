defmodule Sake.Client.Session do
  @moduledoc "The state of a client connection; every `Sake.Client` call returns an updated one."
  @type t :: %__MODULE__{}
  defstruct [
    :url,
    :era,
    :revision,
    :session_id,
    :server_info,
    :server_capabilities,
    :instructions,
    :on_input,
    :on_notification,
    :stdio,
    :auth,
    headers: [],
    client_info: %{},
    capabilities: %{},
    next_id: 1,
    tools: %{},
    req: []
  ]
end
