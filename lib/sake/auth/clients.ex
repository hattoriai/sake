defmodule Sake.Auth.Clients do
  @moduledoc """
  Clients the host registers itself (for its own CLIs or partners).

      {:ok, client, secret} = Sake.Auth.Clients.create(Sake.Auth.config(), %{name: "Ops CLI", redirect_uris: ["http://127.0.0.1:8765/callback"]})

  `confidential: true` returns a secret once; store it where the client
  can read it. `scopes:` limits what the client may request.

  A machine client — a service that calls your endpoint as itself, with
  the client credentials grant — needs no redirect URI, and must be able
  to authenticate: with a secret, or with a key it holds (`jwks:`, a JWK
  Set of its public keys, or `jwks_uri:`, where to fetch them; the
  client then signs a JWT for each token request, `private_key_jwt`).
  Keys need the optional `jose` dependency.

      {:ok, client, nil} =
        Sake.Auth.Clients.create(config, %{
          name: "Nightly report",
          grant_types: ["client_credentials"],
          jwks: %{"keys" => [public_jwk]},
          scopes: ["reports:read"]
        })

  `grant_types:` (default `["authorization_code", "refresh_token"]`) may
  also list `"client_credentials"` (with the subject module's
  `c:Sake.Auth.Subject.client_principal/1`) and
  `"urn:ietf:params:oauth:grant-type:jwt-bearer"`, for grants from a
  `Sake.Auth.TrustedIssuer`.

  `dpop_bound_access_tokens: true` (RFC 9449 §5.2) refuses the client's
  token requests that carry no DPoP proof, so all its tokens are bound
  to a key it holds.
  """

  alias Sake.Auth.{Client, Config, Redirect, Tokens}

  @jwt_bearer "urn:ietf:params:oauth:grant-type:jwt-bearer"
  @grant_types ["authorization_code", "refresh_token", "client_credentials", @jwt_bearer]
  @default_grant_types ["authorization_code", "refresh_token"]

  @spec create(Config.t(), map()) :: {:ok, Client.t(), String.t() | nil} | {:error, map()}
  def create(config, attrs) do
    grant_types = attrs[:grant_types] || @default_grant_types

    case validate(config, attrs, grant_types) do
      errors when errors == %{} -> persist(config, attrs, grant_types)
      errors -> {:error, errors}
    end
  end

  defp validate(config, attrs, grant_types) do
    %{}
    |> validate_name(attrs[:name])
    |> validate_grant_types(grant_types)
    |> validate_redirect_uris(attrs[:redirect_uris] || [], grant_types)
    |> validate_keys(config, attrs)
    |> validate_machine(config, attrs, grant_types)
  end

  defp validate_name(errors, name) do
    if is_binary(name) and String.length(name) in 1..100,
      do: errors,
      else: Map.put(errors, :name, "must be 1 to 100 characters")
  end

  defp validate_grant_types(errors, grant_types) do
    if is_list(grant_types) and grant_types != [] and grant_types -- @grant_types == [],
      do: errors,
      else: Map.put(errors, :grant_types, "must be some of #{Enum.join(@grant_types, ", ")}")
  end

  # Only the authorization code grant sends anyone to a redirect URI.
  defp validate_redirect_uris(errors, uris, grant_types) do
    if is_list(grant_types) and "authorization_code" not in grant_types and uris == [],
      do: errors,
      else: validate_uris(errors, uris)
  end

  defp validate_uris(errors, []), do: Map.put(errors, :redirect_uris, "must not be empty")

  defp validate_uris(errors, uris) do
    if Enum.all?(uris, &Redirect.valid?/1),
      do: errors,
      else: Map.put(errors, :redirect_uris, "must be https or loopback http URLs")
  end

  defp validate_keys(errors, config, attrs) do
    confidential = attrs[:confidential] == true

    case {attrs[:jwks], attrs[:jwks_uri]} do
      {nil, nil} ->
        errors

      _keys when confidential ->
        Map.put(errors, :jwks, "a client authenticates with a secret or with keys, not both")

      {jwks, nil} ->
        if jwks?(jwks),
          do: with_jose(errors),
          else: Map.put(errors, :jwks, "must be a JWK Set of public keys (%{\"keys\" => [...]})")

      {nil, uri} ->
        if https?(config, uri),
          do: with_jose(errors),
          else: Map.put(errors, :jwks_uri, "must be an https URL")

      _both ->
        Map.put(errors, :jwks, "give jwks or jwks_uri, not both")
    end
  end

  defp with_jose(errors) do
    Sake.Auth.JWT.require!("A client with jwks: or jwks_uri:")
    errors
  end

  defp jwks?(%{"keys" => [_ | _] = keys}),
    do: Enum.all?(keys, &(is_map(&1) and is_binary(&1["kty"]) and not Map.has_key?(&1, "d")))

  defp jwks?(_jwks), do: false

  defp https?(config, url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> true
      %URI{scheme: "http", host: host} when is_binary(host) -> config.allow_insecure
      _ -> false
    end
  end

  defp https?(_config, _url), do: false

  # RFC 6749 §4.4: the client credentials grant is for confidential
  # clients only, and Sake issues its tokens only for a principal the
  # host's subject module names.
  defp validate_machine(errors, config, attrs, grant_types) do
    cond do
      not (is_list(grant_types) and "client_credentials" in grant_types) ->
        errors

      attrs[:confidential] != true and is_nil(attrs[:jwks]) and is_nil(attrs[:jwks_uri]) ->
        Map.put(
          errors,
          :grant_types,
          "client_credentials needs a confidential client (confidential: true, jwks: or jwks_uri:)"
        )

      not client_principal?(config.subject) ->
        Map.put(
          errors,
          :grant_types,
          "client_credentials needs the subject module's client_principal/1"
        )

      true ->
        errors
    end
  end

  defp client_principal?(subject) do
    Code.ensure_loaded(subject)
    function_exported?(subject, :client_principal, 1)
  end

  defp persist(config, attrs, grant_types) do
    {method, secret} = auth_method(attrs)

    client = %Client{
      id: "rc_" <> Tokens.generate(),
      name: attrs[:name],
      kind: :registered,
      redirect_uris: attrs[:redirect_uris] || [],
      grant_types: grant_types,
      token_endpoint_auth_method: method,
      secret_hash: secret && Tokens.hash(secret),
      scopes: attrs[:scopes],
      client_uri: attrs[:client_uri],
      logo_uri: attrs[:logo_uri],
      jwks: attrs[:jwks],
      jwks_uri: attrs[:jwks_uri],
      application_type: attrs[:application_type] || "native",
      dpop_bound_access_tokens: attrs[:dpop_bound_access_tokens] == true
    }

    {module, state} = Sake.Auth.store(config)
    :ok = module.put_client(state, client)
    {:ok, client, secret}
  end

  defp auth_method(%{confidential: true}), do: {"client_secret_basic", Tokens.generate()}
  defp auth_method(%{jwks: %{}}), do: {"private_key_jwt", nil}
  defp auth_method(%{jwks_uri: uri}) when is_binary(uri), do: {"private_key_jwt", nil}
  defp auth_method(_attrs), do: {"none", nil}

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

  @doc "Finds a client by id: a CIMD URL is fetched, anything else is looked up in the store."
  @spec resolve(Config.t(), term()) ::
          {:ok, Client.t()}
          | {:error, :invalid_client | :not_allowed | :unreachable | :invalid_document}
  def resolve(config, id) when is_binary(id) do
    if String.starts_with?(id, "http") do
      Sake.Auth.CIMD.fetch(config, id)
    else
      case get(config, id) do
        {:ok, client} -> {:ok, client}
        :error -> {:error, :invalid_client}
      end
    end
  end

  def resolve(_config, _id), do: {:error, :invalid_client}

  @doc false
  # The optional metadata of a registration request or a metadata
  # document: each field is absent or of its one allowed type.
  @spec metadata_types_valid?(map()) :: boolean()
  def metadata_types_valid?(doc) do
    Enum.all?(~w(client_uri logo_uri application_type scope), &optional_string?(doc[&1])) and
      optional_strings?(doc["grant_types"]) and
      doc["dpop_bound_access_tokens"] in [nil, true, false]
  end

  defp optional_string?(value), do: is_nil(value) or is_binary(value)

  defp optional_strings?(nil), do: true
  defp optional_strings?(list) when is_list(list), do: Enum.all?(list, &is_binary/1)
  defp optional_strings?(_), do: false
end
