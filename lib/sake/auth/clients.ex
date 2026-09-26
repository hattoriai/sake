defmodule Sake.Auth.Clients do
  @moduledoc """
  Clients the host registers itself (for its own CLIs or partners).

      {:ok, client, secret} = Sake.Auth.Clients.create(Sake.Auth.config(), %{name: "Ops CLI", redirect_uris: ["http://127.0.0.1:8765/callback"]})

  `confidential: true` returns a secret once; store it where the client
  can read it. `scopes:` limits what the client may request.
  """

  alias Sake.Auth.{Client, Config, Redirect, Tokens}

  @spec create(Config.t(), map()) :: {:ok, Client.t(), String.t() | nil} | {:error, map()}
  def create(config, attrs) do
    case validate(attrs) do
      errors when errors == %{} -> persist(config, attrs)
      errors -> {:error, errors}
    end
  end

  defp validate(attrs) do
    %{}
    |> validate_name(attrs[:name])
    |> validate_uris(attrs[:redirect_uris] || [])
  end

  defp validate_name(errors, name) do
    if is_binary(name) and String.length(name) in 1..100,
      do: errors,
      else: Map.put(errors, :name, "must be 1 to 100 characters")
  end

  defp validate_uris(errors, []), do: Map.put(errors, :redirect_uris, "must not be empty")

  defp validate_uris(errors, uris) do
    if Enum.all?(uris, &Redirect.valid?/1),
      do: errors,
      else: Map.put(errors, :redirect_uris, "must be https or loopback http URLs")
  end

  defp persist(config, attrs) do
    {method, secret} = auth_method(attrs[:confidential])

    client = %Client{
      id: "rc_" <> Tokens.generate(),
      name: attrs[:name],
      kind: :registered,
      redirect_uris: attrs[:redirect_uris] || [],
      token_endpoint_auth_method: method,
      secret_hash: secret && Tokens.hash(secret),
      scopes: attrs[:scopes],
      client_uri: attrs[:client_uri],
      logo_uri: attrs[:logo_uri],
      application_type: attrs[:application_type] || "native"
    }

    {module, state} = Sake.Auth.store(config)
    :ok = module.put_client(state, client)
    {:ok, client, secret}
  end

  defp auth_method(true), do: {"client_secret_basic", Tokens.generate()}
  defp auth_method(_), do: {"none", nil}

  @spec get(Config.t(), String.t()) :: {:ok, Client.t()} | :error
  def get(config, id) do
    {module, state} = Sake.Auth.store(config)
    module.get_client(state, id)
  end

  @spec list(Config.t()) :: [Client.t()]
  def list(config) do
    {module, state} = Sake.Auth.store(config)
    module.list_clients(state)
  end

  @spec delete(Config.t(), String.t()) :: :ok
  def delete(config, id) do
    {module, state} = Sake.Auth.store(config)
    module.delete_client(state, id)
  end
end
