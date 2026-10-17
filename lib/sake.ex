defmodule Sake do
  @moduledoc """
  Sake is MCP for Elixir and Phoenix.

  See `Sake.Server` to expose tools, `Sake.Plug` to mount the endpoint,
  `Sake.Auth` to protect it with your own login, and `Sake.Client` to call
  other servers.

  ## Configuration

    * `config :sake, :json_library, Jason` — the library Sake encodes
      your data with (tool results, resources, prompts, notifications):
      `JSON` (the default), `Jason`, or any module with `encode!/1` and
      `encode_to_iodata!/1`. Choose Jason when your structs derive
      `Jason.Encoder` rather than `JSON.Encoder`. See the tools guide.
    * `config :sake, :secret_key_base` — the signing secret, when neither
      `Sake.Plug` nor `{Sake, ...}` is given one.
    * `config :sake, :opentelemetry` — see the observability guide.
  """

  @version Mix.Project.config()[:version]

  @doc "The package version."
  @spec version() :: String.t()
  def version, do: @version

  @doc """
  The child for the host's supervision tree:

      {Sake, secret_key_base: {MyAppWeb.Endpoint, :config, [:secret_key_base]}, pubsub: MyApp.PubSub, auth: [...]}

  `auth:` takes the `Sake.Auth.Config` options, for Sake's own
  authorization server; `external_auth:` names other authorization
  servers whose tokens endpoints take (see `Sake.Auth.External`); without
  either only the stream registry and tasks run. `tasks:` takes the
  `Sake.Tasks` options (`false` turns tasks off).

  `replay:` is the `Sake.Auth.Store` that remembers the single-use JWTs
  already seen (client assertions, JWT grants, DPoP proofs), as
  `{module, options}`; by default the `auth:` store. On several nodes it
  must be shared, `{Sake.Auth.Store.Ecto, repo: MyApp.Repo}`, for a JWT
  used on one node to be refused on the others; a deployment with only
  `external_auth:` and DPoP sets it to have that. Without either, each
  node remembers on its own.

  When a store, the replay table or the streams keep their state on this
  node only (the ETS stores, no `replay:` store, no `pubsub:`), Sake logs
  a warning once this node is connected to another, naming each and its
  shared alternative. See the "Running on several nodes" guide.
  """
  def child_spec(opts) do
    %{id: __MODULE__, type: :supervisor, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc false
  def start_link(opts) do
    Sake.JSON.configure!()

    # Kept as given: an `{m, f, a}` is called when the secret is first
    # needed, as it may name something that starts after Sake.
    if secret = opts[:secret_key_base],
      do: :persistent_term.put({Sake, :secret_key_base}, Sake.Secret.validate!(secret))

    # Authorization reads the secret from its configurations, never from
    # the rest of Sake: it is handed to them here, still unresolved.
    secret =
      if opts[:auth] || opts[:external_auth] not in [nil, []], do: Sake.Secret.unresolved()

    auth =
      case opts[:auth] do
        nil -> nil
        auth_opts -> Sake.Auth.Config.new(Keyword.put(auth_opts, :secret, secret))
      end

    external =
      (opts[:external_auth] || [])
      |> Enum.map(fn {name, ext_opts} -> {name, Keyword.put(ext_opts, :secret, secret)} end)
      |> Sake.Auth.External.new_all(auth)

    children =
      if(Keyword.get(opts, :streams, true),
        do: [Sake.Plug.Streams.child_spec(pubsub: opts[:pubsub])],
        else: []
      ) ++
        [{Sake.Auth.Supervisor, auth: auth, external: external, replay: opts[:replay]}] ++
        tasks_children(Keyword.get(opts, :tasks, [])) ++
        cluster_children(Sake.Cluster.local_state(opts, auth, external))

    Supervisor.start_link(children, strategy: :one_for_one, name: Sake.Supervisor)
  end

  defp tasks_children(false), do: []
  defp tasks_children(opts), do: [{Sake.Tasks, opts}]

  defp cluster_children([]), do: []
  defp cluster_children(local), do: [{Sake.Cluster, local}]
end
