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
    :sampling,
    :roots,
    :on_notification,
    :log_level,
    :stdio,
    :local,
    :auth,
    headers: [],
    client_info: %{},
    capabilities: %{},
    next_id: 1,
    tools: %{},
    tasks: true,
    task_timeout: 300_000,
    max_response_size: 16_777_216,
    max_reconnects: 3,
    req: []
  ]
end
