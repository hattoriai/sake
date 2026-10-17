defmodule Sake.Auth.Supervisor do
  @moduledoc false
  # Authorization, as one child of `Sake`: the configurations, which it
  # publishes for the plugs to read, and the processes they need. The
  # `auth:` store's own process when it has one; the client metadata and
  # JWKS cache and the replay table when there is any authorization
  # server; the introspection cache when there is an external one.
  #
  # Options: `auth:` (a `Sake.Auth.Config`, or nil), `external:` (the
  # `Sake.Auth.External` configurations by name) and `replay:` (the
  # `Sake` child's option: `{module, options}` of a `Sake.Auth.Store`, or
  # nil for the `auth:` store, or this node's table without one).
  #
  # The configurations are published, and the replay store set, even
  # when there is nothing to run, so a `Sake` started without them
  # replaces those of one that ran before.
  use Supervisor

  alias Sake.Auth.{CIMD, Config, External, Replay}

  def start_link(opts) do
    auth = opts[:auth]
    external = opts[:external] || %{}

    Replay.configure(replay_store(opts[:replay], auth))
    :persistent_term.put({Sake.Auth, :config}, auth)
    :persistent_term.put({External, :configs}, external)

    Supervisor.start_link(__MODULE__, {auth, external}, name: __MODULE__)
  end

  @impl true
  def init({auth, external}) do
    children =
      store_children(auth) ++
        if(auth || external != %{}, do: [CIMD.Cache, Replay], else: []) ++
        if(external != %{}, do: [External.Cache], else: [])

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp store_children(%Config{store: {module, opts}}) do
    if function_exported?(module, :child_spec, 1), do: [module.child_spec(opts)], else: []
  end

  defp store_children(nil), do: []

  defp replay_store({module, opts}, _auth), do: {module, module.init(opts)}
  defp replay_store(nil, %Config{store: {module, _}, store_state: state}), do: {module, state}
  defp replay_store(nil, nil), do: nil
end
