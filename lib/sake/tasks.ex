defmodule Sake.Tasks do
  @moduledoc """
  Tools that run as tasks: the `io.modelcontextprotocol/tasks` extension
  of the modern protocol.

      defmodule MyApp.MCP.Export do
        use Sake.Tool, name: "export", task: :optional
        arg :project, :string, required: true

        @impl true
        def execute(%{project: project}, ctx) do
          files = Projects.files(project)

          exported =
            Enum.reduce_while(files, 0, fn file, n ->
              if Sake.Tasks.cancelled?(ctx) do
                {:halt, n}
              else
                Export.file(file)
                Sake.Progress.report(ctx, n + 1, length(files))
                {:cont, n + 1}
              end
            end)

          {:ok, "Exported \#{exported} of \#{length(files)} files."}
        end
      end

  When a client declares the extension in a request's capabilities, a
  call to a tool with `task: :optional` (or `true`) or `task: :required`
  answers at once with a task, and `execute/2` runs in the background; the
  client polls `tasks/get` until the task ends. Without the extension, an
  optional task tool runs like any other tool, and a required one is
  refused with `-32021`. Arguments and scopes are checked before a task
  exists, and a tool's `prepare/2` runs first, so it can still ask the
  client for input on the original request (see `Sake.Tool`).

  Inside a task, `Sake.Elicit`, `Sake.Sampling` and `Sake.Roots` move the
  task to `input_required` and wait for the client's `tasks/update`
  (keys must be unique over the task's life: asking a key again returns
  the first answer); `Sake.Progress.report/4` sets the task's
  `statusMessage`; `cancelled?/1` tells whether the client cancelled.
  Cancelling marks the task cancelled at once and stops its process when
  it runs on the node that received `tasks/cancel`; elsewhere, the tool
  sees the cancellation when it next waits for input (a cancelled
  elicitation, `{:error, :cancelled}` from sampling and roots) or calls
  `cancelled?/1`.

  A task belongs to whoever created it: the token's subject when the
  endpoint has authorization, otherwise the host's scope (see `Sake.Plug`'s
  `scope:`). Any other caller is told the task does not exist. Task IDs
  carry 144 random bits.

  Tasks are configured on the `Sake` child:

      {Sake, secret_key_base: ..., tasks: [store: {Sake.Tasks.Store.Ecto, repo: MyApp.Repo}]}

  Options: `store` (default `Sake.Tasks.Store.ETS`, which keeps tasks on
  one node; use `Sake.Tasks.Store.Ecto` when the endpoint runs on
  several), `ttl` (how long a task is kept after it was created, in ms;
  default one hour) and `poll_interval` (the `pollIntervalMs` suggested to
  clients, and how often a waiting task checks the store; default one
  second). `tasks: false` turns tasks off: task tools then run like any
  other tool, and the extension is not advertised.

  Telemetry: `[:sake, :task, :start | :stop | :exception]` around the
  tool's run, with `task_id`, `tool` and `server` in the metadata, and the
  final `status` on `:stop`. With OpenTelemetry, the run is an
  `execute_tool` span, the child of the span of the `tools/call` that
  started it (see `guides/observability.md`).
  """

  alias Sake.Context
  alias Sake.Tasks.Record

  @extension "io.modelcontextprotocol/tasks"
  @defaults [store: {Sake.Tasks.Store.ETS, []}, ttl: 3_600_000, poll_interval: 1_000]

  @doc "Whether the client asked to cancel the task the component runs in; always `false` outside a task."
  @spec cancelled?(Context.t()) :: boolean()
  def cancelled?(%Context{task: id}) when is_binary(id) do
    case fetch(id) do
      {:ok, %Record{status: :cancelled}} -> true
      {:ok, _record} -> false
      :error -> true
    end
  end

  def cancelled?(_ctx), do: false

  @doc false
  def extension, do: @extension

  @doc false
  # Whether tasks run on this node: without them (`tasks: false`), task
  # tools run like any other tool and the extension is not advertised.
  def running?, do: Process.whereis(__MODULE__.Registry) != nil

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, type: :supervisor, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc false
  def start_link(opts) do
    opts = Keyword.merge(@defaults, opts)
    {module, store_opts} = opts[:store]

    :persistent_term.put({__MODULE__, :config}, %{
      store: {module, module.init(store_opts)},
      ttl: opts[:ttl],
      poll_interval: opts[:poll_interval]
    })

    store =
      if function_exported?(module, :child_spec, 1), do: [module.child_spec(store_opts)], else: []

    children =
      store ++
        [
          {Registry, keys: :duplicate, name: __MODULE__.Registry},
          {Task.Supervisor, name: __MODULE__.Supervisor},
          __MODULE__.Pruner
        ]

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__.Root)
  end

  @doc false
  def config do
    :persistent_term.get({__MODULE__, :config}, nil) ||
      raise "Sake.Tasks is not running: add {Sake, ...} to your supervision tree"
  end

  # ---- the store, as the rest of Sake uses it: expired tasks are gone.

  @doc false
  @spec create(Context.t(), String.t()) :: Record.t()
  def create(ctx, tool) do
    %{store: {module, state}, ttl: ttl, poll_interval: poll} = config()
    now = now()

    record = %Record{
      id: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false),
      principal: principal(ctx),
      tool: tool,
      ttl_ms: ttl,
      poll_interval_ms: poll,
      created_at: now,
      updated_at: now,
      expires_at: DateTime.add(now, ttl, :millisecond)
    }

    :ok = module.insert(state, record)
    record
  end

  @doc false
  @spec fetch(String.t()) :: {:ok, Record.t()} | :error
  def fetch(id) do
    %{store: {module, state}} = config()

    case module.get(state, id) do
      {:ok, record} -> if Record.expired?(record, now()), do: :error, else: {:ok, record}
      :error -> :error
    end
  end

  @doc false
  # Updates the task and, when its status changed, tells the listen
  # streams of `server` on every node.
  @spec update(module(), String.t(), (Record.t() -> Record.t())) :: {:ok, Record.t()} | :error
  def update(server, id, fun) do
    %{store: {module, state}} = config()
    now = now()

    case module.update(state, id, &touch(&1, fun.(&1), now)) do
      {:ok, before, updated} ->
        cond do
          Record.expired?(before, now) ->
            :error

          before.status != updated.status ->
            Sake.Plug.Streams.broadcast(server, {:task, Record.to_wire(updated)})
            {:ok, updated}

          true ->
            {:ok, updated}
        end

      :error ->
        :error
    end
  end

  defp touch(before, updated, _now) when before == updated, do: updated
  defp touch(_before, updated, now), do: %{updated | updated_at: now}

  @doc false
  # The principal a task is bound to: the token's subject (or its client),
  # else the host's
  # scope (as `Sake.Server.RequestState` binds a request state). The scope
  # is kept as a digest, since the store may be a database.
  @spec principal(Context.t()) :: String.t() | nil
  def principal(%Context{token: %{subject_id: id}}) when is_binary(id), do: "subject:" <> id

  # A machine client's token (client credentials) has no subject: the
  # client is the principal.
  def principal(%Context{token: %{subject_id: nil, client_id: id}}) when is_binary(id),
    do: "client:" <> id

  def principal(%Context{scope: nil}), do: nil

  def principal(%Context{scope: scope}),
    do: "scope:" <> Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary(scope)))

  @doc false
  # Wakes this node's processes waiting on the task, so an answer or a
  # cancellation is seen at once rather than at the next poll.
  def wake(id), do: dispatch(id, &send(&1, {:sake_task_wake, id}))

  @doc false
  # Stops this node's processes running the task.
  def stop(id), do: dispatch(id, &Process.exit(&1, :kill))

  defp dispatch(id, fun) do
    if Process.whereis(__MODULE__.Registry),
      do: Registry.dispatch(__MODULE__.Registry, id, &each_pid(&1, fun))

    :ok
  end

  defp each_pid(entries, fun), do: Enum.each(entries, fn {pid, _} -> fun.(pid) end)

  @doc false
  def now, do: DateTime.utc_now() |> DateTime.truncate(:millisecond)

  defmodule Pruner do
    @moduledoc false
    # Deletes expired tasks from the store every minute. Several nodes
    # pruning the same database is harmless.
    use GenServer

    @interval 60_000

    def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

    @impl true
    def init(nil) do
      Process.send_after(self(), :prune, @interval)
      {:ok, nil}
    end

    @impl true
    def handle_info(:prune, state) do
      %{store: {module, store}} = Sake.Tasks.config()
      :ok = module.prune(store, Sake.Tasks.now())
      Process.send_after(self(), :prune, @interval)
      {:noreply, state}
    end
  end
end
