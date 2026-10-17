defmodule Sake.Auth.AuthorizationRequest do
  @moduledoc false
  # An authorization request, validated: the client, where the code goes,
  # the PKCE challenge, the scopes and the resource (RFC 8707) it is for.
  #
  # `validate/3` takes the request's parameters as a map of strings,
  # wherever they came from: the authorize endpoint's query string today,
  # a pushed authorization request or a device authorization request
  # later. Parameters a later endpoint adds (`nonce`, `max_age`,
  # `acr_values`) go in `extra`, so the struct and `validate/3` keep their
  # shape.
  #
  # Core: it takes the configuration and plain data, and never sees the
  # conn.

  alias Sake.Auth.{Client, Clients, Config, Redirect, Resource}

  @type t :: %__MODULE__{
          client_id: String.t(),
          redirect_uri: String.t(),
          state: String.t() | nil,
          code_challenge: String.t(),
          scopes: [String.t()],
          resource: String.t(),
          extra: map()
        }
  defstruct [
    :client_id,
    :redirect_uri,
    :state,
    :code_challenge,
    :resource,
    scopes: [],
    extra: %{}
  ]

  @doc """
  The client of a request, and whether `redirect_uri` is one it
  registered. An error here is never sent to the redirect URI: nothing
  says it is the client's.
  """
  @spec client(Config.t(), term(), term()) ::
          {:ok, Client.t()}
          | {:error, :unknown_client}
          | {:error, :client, term()}
          | {:error, :redirect_uri}
  def client(config, client_id, redirect_uri) do
    case Clients.resolve(config, client_id) do
      {:ok, client} ->
        if is_binary(redirect_uri) and Redirect.matches?(client.redirect_uris, redirect_uri),
          do: {:ok, client},
          else: {:error, :redirect_uri}

      {:error, :invalid_client} ->
        {:error, :unknown_client}

      {:error, reason} ->
        {:error, :client, reason}
    end
  end

  @doc """
  Validates the parameters of a request from `client` (whose
  `redirect_uri` `client/3` accepted). An error is an OAuth error code and
  its description, for the redirect URI.
  """
  @spec validate(Config.t(), Client.t(), map()) :: {:ok, t()} | {:error, String.t(), String.t()}
  def validate(config, client, p) do
    known = config |> Config.scopes() |> Enum.map(&elem(&1, 0))
    requested = requested_scopes(p, known)

    with :ok <- check_response_type(p),
         :ok <- check_challenge(p),
         :ok <- check_grant_type(client),
         :ok <- check_scopes(requested, known, client),
         {:ok, resource} <- resource(config, p["resource"]) do
      {:ok,
       %__MODULE__{
         client_id: client.id,
         redirect_uri: p["redirect_uri"],
         code_challenge: p["code_challenge"],
         state: p["state"],
         scopes: requested,
         resource: resource
       }}
    else
      :error ->
        {:error, "invalid_target", "The resource is not served by this authorization server"}

      error ->
        error
    end
  end

  defp requested_scopes(p, known) do
    if is_binary(p["scope"]) and p["scope"] != "", do: String.split(p["scope"]), else: known
  end

  defp check_response_type(%{"response_type" => "code"}), do: :ok

  defp check_response_type(_p),
    do: {:error, "unsupported_response_type", "Only response_type=code is supported"}

  defp check_challenge(p) do
    cond do
      not is_binary(p["code_challenge"]) or p["code_challenge"] == "" ->
        {:error, "invalid_request", "code_challenge is required"}

      p["code_challenge_method"] != "S256" ->
        {:error, "invalid_request", "code_challenge_method must be S256"}

      true ->
        :ok
    end
  end

  defp check_grant_type(client) do
    if "authorization_code" in client.grant_types,
      do: :ok,
      else: {:error, "unauthorized_client", "The client may not use the authorization code grant"}
  end

  defp check_scopes(requested, known, client) do
    cond do
      requested -- known != [] ->
        {:error, "invalid_scope", "Unknown scope: #{Enum.join(requested -- known, " ")}"}

      client.scopes && requested -- client.scopes != [] ->
        {:error, "invalid_scope",
         "The client may not request: #{Enum.join(requested -- client.scopes, " ")}"}

      true ->
        :ok
    end
  end

  @doc """
  The resource a request is for (RFC 8707): the `resource` parameter, an
  endpoint URL on the issuer's origin that `resources:` covers, or without
  one the only endpoint when `resources:` names exactly one fixed path.
  `:error` when it is none of those. The token endpoint's grants take the
  same rule.
  """
  @spec resource(Config.t(), term()) :: {:ok, String.t()} | :error
  def resource(config, nil) do
    case config.resources do
      [pattern] ->
        if String.contains?(pattern, ":"), do: :error, else: {:ok, config.issuer <> pattern}

      _ ->
        :error
    end
  end

  def resource(config, value) when is_binary(value) do
    uri = URI.parse(value)
    path = String.trim_trailing(uri.path || "", "/")

    cond do
      not same_origin?(uri, URI.parse(config.issuer)) -> :error
      config.resources == nil -> {:ok, config.issuer <> path}
      Enum.any?(config.resources, &Resource.path_match?(&1, path)) -> {:ok, config.issuer <> path}
      true -> :error
    end
  end

  def resource(_config, _), do: :error

  defp same_origin?(uri, issuer) do
    uri.scheme == issuer.scheme and uri.host == issuer.host and uri.port == issuer.port and
      uri.fragment == nil and uri.query == nil
  end
end
