defmodule Sake.Context do
  @moduledoc """
  What a component learns about the request it serves.

  `scope` is the host's principal (the current user, organization, or
  anything the host puts there); `token` and `scopes` are set when the
  endpoint has authorization; `inputs` holds the client's answers
  (elicitation, sampling, roots) on a retry; `progress` reports progress
  to the client when it asked for it; `task` is the task ID when the
  component runs as a task (see `Sake.Tasks`); `assigns` holds what the
  server's middleware decided for this request (see `Sake.Middleware`).
  """

  @type t :: %__MODULE__{}

  defstruct era: :modern,
            protocol_version: "2026-07-28",
            client_info: %{},
            client_capabilities: %{},
            scope: nil,
            token: nil,
            scopes: [],
            request_id: nil,
            method: nil,
            trace: %{},
            log_level: nil,
            inputs: %{},
            assigns: %{},
            conn_assigns: %{},
            progress: nil,
            server: nil,
            transport: nil,
            task: nil,
            secret: nil,
            reraise: false

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    ctx = struct!(__MODULE__, opts)
    %{ctx | progress: ctx.progress || fn _current, _total_and_message -> :ok end}
  end
end
