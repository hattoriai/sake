defmodule Sake.Tasks.Job do
  @moduledoc """
  What a run of a task needs: the task, the server and tool, the
  validated arguments, and the request's context as the tool sees it
  (`ctx.scope`, the token, the client's capabilities and protocol
  revision, the middleware's assigns). A `Sake.Tasks.Runner` gets one to
  start, and whatever runs it calls `Sake.Tasks.run/1` with it.

  A job crosses process and node boundaries, and a durable queue may keep
  it for a while: `encode/1` turns it into a signed, URL-safe string (a
  job argument of Oban, say), and `decode/1` back. The context's `scope`
  is the host's principal as the tool saw it, so it must survive that
  trip: plain data, no PIDs or functions.

  `run_id` names the run the job was dispatched for: the run that claims
  the task with it (see `Sake.Tasks.run/1`). `attempt` counts the runs.
  """

  @type t :: %__MODULE__{
          task_id: String.t(),
          server: module(),
          tool: String.t(),
          args: map(),
          context: map(),
          attempt: pos_integer(),
          run_id: String.t()
        }

  defstruct [:task_id, :server, :tool, :args, :run_id, context: %{}, attempt: 1]

  # The context fields a run gets back (the method is the `tools/call`
  # that started the task, which its middleware sees); the rest (the
  # transport, progress, the request's ID) belong to that request.
  @kept [
    :method,
    :era,
    :protocol_version,
    :client_info,
    :client_capabilities,
    :scope,
    :token,
    :scopes,
    :assigns,
    :conn_assigns,
    :base_url,
    :log_level,
    :prefixes
  ]

  @salt "sake tasks job"

  @doc false
  # The job of a task the request starts.
  @spec new(String.t(), Sake.Tool.Spec.t(), map(), Sake.Context.t()) :: t()
  def new(task_id, spec, args, ctx) do
    %__MODULE__{
      task_id: task_id,
      server: ctx.server,
      tool: spec.name,
      args: args,
      context: Map.take(Map.from_struct(ctx), @kept),
      run_id: run_id()
    }
  end

  @doc false
  def run_id, do: "run:" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

  @doc false
  # The context the run executes with.
  @spec context(t()) :: Sake.Context.t()
  def context(%__MODULE__{} = job) do
    struct(Sake.Context, Map.merge(job.context, %{server: job.server, task: job.task_id}))
  end

  @doc """
  The job as a signed, URL-safe string, for a queue to carry. Signed with
  Sake's `secret_key_base` (see `Sake`), so `decode/1` refuses a job
  anyone else wrote.
  """
  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{} = job) do
    Plug.Crypto.MessageVerifier.sign(:erlang.term_to_binary(job), key())
  end

  @doc """
  The job `encode/1` made, or `:error` for a string it did not make (or
  signed with another secret), or one whose modules this node does not
  know.
  """
  @spec decode(String.t()) :: {:ok, t()} | :error
  def decode(encoded) when is_binary(encoded) do
    with {:ok, binary} <- Plug.Crypto.MessageVerifier.verify(encoded, key()),
         %__MODULE__{} = job <- :erlang.binary_to_term(binary, [:safe]) do
      {:ok, job}
    else
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp key do
    Plug.Crypto.KeyGenerator.generate(Sake.Secret.fetch!(), @salt, cache: Plug.Crypto.Keys)
  end
end
