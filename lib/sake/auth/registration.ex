defmodule Sake.Auth.Registration do
  @moduledoc false
  # Dynamic Client Registration (RFC 7591) for clients that do not use Client
  # ID Metadata Documents. Public clients only; no authentication.
  #
  # A client that sends no `grant_types` is registered for both the
  # authorization code and the refresh token grants, and the response says
  # so.
  #
  # Core: it takes the configuration and the decoded metadata document,
  # and never sees the conn; `Sake.Auth.DCR` reads the request and renders
  # the answer.

  alias Sake.Auth.{Client, Config, Redirect, Tokens}

  @grant_types ["authorization_code", "refresh_token"]

  @doc """
  Registers a client from its metadata document (RFC 7591 §2): the
  registration response, or the error code of a document that is not
  acceptable.
  """
  @spec register(Config.t(), term()) :: {:ok, map()} | {:error, String.t()}
  def register(config, doc) when is_map(doc) do
    case build(doc) do
      {:ok, client} ->
        {module, state} = Sake.Auth.store(config)
        :ok = module.put_client(state, client)

        {:ok,
         %{
           "client_id" => client.id,
           "client_id_issued_at" => System.system_time(:second),
           "client_name" => client.name,
           "redirect_uris" => client.redirect_uris,
           "grant_types" => client.grant_types,
           "response_types" => ["code"],
           "token_endpoint_auth_method" => "none",
           "application_type" => client.application_type,
           "dpop_bound_access_tokens" => client.dpop_bound_access_tokens
         }}

      {:error, code} ->
        {:error, code}
    end
  end

  def register(_config, _doc), do: {:error, "invalid_client_metadata"}

  defp build(doc) do
    with :ok <- validate(doc) do
      {:ok, client_from(doc)}
    end
  end

  defp validate(doc) do
    with :ok <- validate_redirect_uris(doc["redirect_uris"]),
         :ok <- validate_name(doc["client_name"] || "Unnamed client"),
         :ok <- validate_auth_method(doc["token_endpoint_auth_method"]),
         :ok <- validate_types(doc) do
      validate_grants(doc["grant_types"] || @grant_types)
    end
  end

  defp validate_types(doc) do
    if Sake.Auth.Clients.metadata_types_valid?(doc),
      do: :ok,
      else: {:error, "invalid_client_metadata"}
  end

  defp validate_redirect_uris(uris) do
    cond do
      not (is_list(uris) and uris != [] and Enum.all?(uris, &Redirect.valid?/1)) ->
        {:error, "invalid_redirect_uri"}

      length(uris) > 10 ->
        {:error, "invalid_client_metadata"}

      true ->
        :ok
    end
  end

  defp validate_name(name) do
    if is_binary(name) and String.length(name) in 1..100,
      do: :ok,
      else: {:error, "invalid_client_metadata"}
  end

  defp validate_auth_method(method) do
    if (method || "none") == "none", do: :ok, else: {:error, "invalid_client_metadata"}
  end

  defp validate_grants(grants) do
    if is_list(grants) and grants -- @grant_types == [],
      do: :ok,
      else: {:error, "invalid_client_metadata"}
  end

  defp client_from(doc) do
    %Client{
      id: "dc_" <> Tokens.generate(),
      name: doc["client_name"] || "Unnamed client",
      kind: :dynamic,
      redirect_uris: doc["redirect_uris"],
      grant_types: doc["grant_types"] || @grant_types,
      token_endpoint_auth_method: "none",
      client_uri: doc["client_uri"],
      logo_uri: doc["logo_uri"],
      scopes: if(is_binary(doc["scope"]), do: String.split(doc["scope"]), else: nil),
      application_type: doc["application_type"] || "native",
      dpop_bound_access_tokens: doc["dpop_bound_access_tokens"] == true,
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end
end
