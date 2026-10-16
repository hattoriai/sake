defmodule Sake do
  @moduledoc """
  Sake is MCP for Elixir and Phoenix.

  See `Sake.Server` to expose tools, `Sake.Plug` to mount the endpoint,
  `Sake.Auth` to protect it with your own login, and `Sake.Client` to call
  other servers.
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
  """
  def child_spec(opts) do
    %{id: __MODULE__, type: :supervisor, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc false
  def start_link(opts) do
    if secret = opts[:secret_key_base],
      do: :persistent_term.put({Sake, :secret_key_base}, Sake.Secret.resolve(secret))

    auth =
      case opts[:auth] do
        nil -> nil
        auth_opts -> Sake.Auth.Config.new(auth_opts)
      end

    external = Sake.Auth.External.new_all(opts[:external_auth] || [], auth)

    :persistent_term.put({Sake, :auth}, auth)
    :persistent_term.put({Sake, :external_auth}, external)

    children =
      if(Keyword.get(opts, :streams, true),
        do: [Sake.Plug.Streams.child_spec(pubsub: opts[:pubsub])],
        else: []
      ) ++
        store_children(auth) ++
        if(auth || external != %{}, do: [Sake.Auth.CIMD.Cache, Sake.Auth.Replay], else: []) ++
        if(external != %{}, do: [Sake.Auth.External.Cache], else: []) ++
        tasks_children(Keyword.get(opts, :tasks, []))

    Supervisor.start_link(children, strategy: :one_for_one, name: Sake.Supervisor)
  end

  defp store_children(%Sake.Auth.Config{store: {module, opts}}) do
    if function_exported?(module, :child_spec, 1), do: [module.child_spec(opts)], else: []
  end

  defp store_children(nil), do: []

  defp tasks_children(false), do: []
  defp tasks_children(opts), do: [{Sake.Tasks, opts}]
end
