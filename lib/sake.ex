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

  `auth:` takes the `Sake.Auth.Config` options; without it only the stream
  registry runs.
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

    :persistent_term.put({Sake, :auth}, auth)

    children =
      if(Keyword.get(opts, :streams, true),
        do: [Sake.Plug.Streams.child_spec(pubsub: opts[:pubsub])],
        else: []
      ) ++
        store_children(auth) ++ if(auth, do: [Sake.Auth.CIMD.Cache], else: [])

    Supervisor.start_link(children, strategy: :one_for_one, name: Sake.Supervisor)
  end

  defp store_children(%Sake.Auth.Config{store: {module, opts}}) do
    if function_exported?(module, :child_spec, 1), do: [module.child_spec(opts)], else: []
  end

  defp store_children(nil), do: []
end
