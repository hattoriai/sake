defmodule Sake.Auth.Registration do
  @moduledoc false
  # Dynamic Client Registration (RFC 7591) for clients that do not use Client
  # ID Metadata Documents. Public clients only; no authentication.
  #
  # A client that sends no `grant_types` is registered for both the
  # authorization code and the refresh token grants, and the response says
  # so. With `device:`, a client may also register for the device code
  # grant (RFC 8628); one that does not ask for the authorization code
  # grant needs no redirect URI (RFC 7591 §2).
  #
  # Core: it takes the configuration and the decoded metadata document,
  # and never sees the conn; `Sake.Auth.DCR` reads the request and renders
  # the answer.

  alias Sake.Auth.{Client, Config, Redirect, Tokens}

  @grant_types ["authorization_code", "refresh_token"]
  @device_code "urn:ietf:params:oauth:grant-type:device_code"

  @doc """
  Registers a client from its metadata document (RFC 7591 §2): the
  registration response, or the error code of a document that is not
  acceptable.
  """
  @spec register(Config.t(), term()) :: {:ok, map()} | {:error, String.t()}
  def register(config, doc) when is_map(doc) do
    case build(config, doc) do
      {:ok, client} ->
        {module, state} = Sake.Auth.store(config)
        :ok = module.put_client(state, client)

        {:ok,
         par_field(config, client, %{
           "client_id" => client.id,
           "client_id_issued_at" => System.system_time(:second),
           "client_name" => client.name,
           "redirect_uris" => client.redirect_uris,
           "grant_types" => client.grant_types,
           "response_types" => response_types(client),
           "token_endpoint_auth_method" => "none",
           "application_type" => client.application_type,
           "dpop_bound_access_tokens" => client.dpop_bound_access_tokens
         })}

      {:error, code} ->
        {:error, code}
    end
  end

  def register(_config, _doc), do: {:error, "invalid_client_metadata"}

  # The response says whether the client's requests must be pushed only
  # on a server that takes pushed requests at all.
  defp par_field(%{par: false}, _client, response), do: response

  defp par_field(_config, client, response),
    do:
      Map.put(
        response,
        "require_pushed_authorization_requests",
        client.require_pushed_authorization_requests
      )

  defp build(config, doc) do
    with :ok <- validate(config, doc) do
      {:ok, client_from(doc)}
    end
  end

  defp validate(config, doc) do
    grants = doc["grant_types"] || @grant_types

    with :ok <- validate_redirect_uris(doc["redirect_uris"], grants),
         :ok <- validate_name(doc["client_name"] || "Unnamed client"),
         :ok <- validate_auth_method(doc["token_endpoint_auth_method"]),
         :ok <- validate_types(config, doc) do
      validate_grants(grants, allowed_grants(config))
    end
  end

  defp allowed_grants(%{device: false}), do: @grant_types
  defp allowed_grants(_config), do: @grant_types ++ [@device_code]

  defp response_types(client),
    do: if("authorization_code" in client.grant_types, do: ["code"], else: [])

  defp validate_types(config, doc) do
    if Sake.Auth.Clients.metadata_types_valid?(doc) and
         Sake.Auth.Clients.par_metadata_valid?(config, doc),
       do: :ok,
       else: {:error, "invalid_client_metadata"}
  end

  # A device client, which never asks for a code, has no redirect URI.
  defp validate_redirect_uris(uris, grants) when uris in [nil, []] and is_list(grants) do
    if @device_code in grants and "authorization_code" not in grants,
      do: :ok,
      else: {:error, "invalid_redirect_uri"}
  end

  defp validate_redirect_uris(uris, _grants) do
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

  defp validate_grants(grants, allowed) do
    if is_list(grants) and grants -- allowed == [],
      do: :ok,
      else: {:error, "invalid_client_metadata"}
  end

  defp client_from(doc) do
    %Client{
      id: "dc_" <> Tokens.generate(),
      name: doc["client_name"] || "Unnamed client",
      kind: :dynamic,
      redirect_uris: doc["redirect_uris"] || [],
      grant_types: doc["grant_types"] || @grant_types,
      token_endpoint_auth_method: "none",
      client_uri: doc["client_uri"],
      logo_uri: doc["logo_uri"],
      scopes: if(is_binary(doc["scope"]), do: String.split(doc["scope"]), else: nil),
      application_type: doc["application_type"] || "native",
      dpop_bound_access_tokens: doc["dpop_bound_access_tokens"] == true,
      require_pushed_authorization_requests: doc["require_pushed_authorization_requests"] == true,
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end
end
