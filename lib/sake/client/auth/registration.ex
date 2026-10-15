defmodule Sake.Client.Auth.Registration do
  @moduledoc false
  # Which client identity to present to an authorization server, in the
  # specification's order of preference: credentials the caller
  # pre-registered, then a Client ID Metadata Document URL when the server
  # supports them, then one registered dynamically (RFC 7591) earlier, then
  # a new dynamic registration.
  #
  # A registration is a map with string keys, so a store can keep it as
  # JSON: `client_id`, `client_secret` (or nil), `token_endpoint_auth_method`
  # and `issuer`, the authorization server it belongs to. Only dynamic
  # registrations are persisted; the other two come from the caller's
  # options on every run.

  alias Sake.Client.Auth
  alias Sake.Client.Auth.HTTP

  @secret_methods ["client_secret_basic", "client_secret_post"]
  @grant_types ["authorization_code", "refresh_token"]

  @spec client(Auth.t(), map()) :: {:ok, map(), Auth.t()} | {:error, term(), Auth.t()}
  def client(auth, %{issuer: issuer, metadata: metadata}) do
    cond do
      auth.client_id ->
        pre_registered(auth, issuer, metadata)

      auth.client_metadata_url && metadata["client_id_metadata_document_supported"] == true ->
        {:ok, metadata_document(auth, issuer), auth}

      registered = Auth.fetch(auth, {:client, issuer}) ->
        {:ok, registered, auth}

      is_binary(metadata["registration_endpoint"]) ->
        register(auth, issuer, metadata)

      true ->
        {:error, :no_client_registration, auth}
    end
  end

  @doc "The registration a stored token was issued to, if the caller still has it."
  @spec for_token(Auth.t(), map()) :: map() | nil
  def for_token(auth, %{"issuer" => issuer, "client_id" => client_id} = token) do
    cond do
      client_id == auth.client_id and auth.client_issuer in [nil, issuer] ->
        %{
          "client_id" => client_id,
          "client_secret" => auth.client_secret,
          "token_endpoint_auth_method" => token["token_endpoint_auth_method"],
          "issuer" => issuer
        }

      client_id == auth.client_metadata_url ->
        metadata_document(auth, issuer)

      true ->
        case Auth.fetch(auth, {:client, issuer}) do
          %{"client_id" => ^client_id} = registered -> registered
          _ -> nil
        end
    end
  end

  # Pre-registered credentials belong to one authorization server (SEP-2352):
  # the issuer the caller names, or else the first one they are used with.
  # Offered to any other, they would leak to a server that never issued
  # them, so the flow stops instead.
  defp pre_registered(%Auth{client_issuer: bound} = auth, issuer, metadata) do
    if bound in [nil, issuer],
      do: {:ok, pre_registered_client(auth, issuer, metadata), %{auth | client_issuer: issuer}},
      else: {:error, {:client_issuer_mismatch, bound, issuer}, auth}
  end

  defp pre_registered_client(auth, issuer, metadata) do
    %{
      "client_id" => auth.client_id,
      "client_secret" => auth.client_secret,
      "token_endpoint_auth_method" =>
        auth.token_endpoint_auth_method || secret_method(auth.client_secret, metadata),
      "issuer" => issuer
    }
  end

  defp secret_method(nil, _metadata), do: "none"

  defp secret_method(_secret, metadata),
    do: Enum.find(@secret_methods, "client_secret_basic", &(&1 in supported_methods(metadata)))

  # A metadata document URL is not bound to any one server: each server
  # fetches the document itself.
  defp metadata_document(auth, issuer) do
    %{
      "client_id" => auth.client_metadata_url,
      "client_secret" => nil,
      "token_endpoint_auth_method" => "none",
      "issuer" => issuer
    }
  end

  # ---- dynamic registration

  defp register(auth, issuer, metadata) do
    method = registration_method(metadata)

    body = %{
      "client_name" => auth.client_name,
      "redirect_uris" => [auth.redirect_uri],
      "grant_types" => grant_types(metadata),
      "response_types" => ["code"],
      "token_endpoint_auth_method" => method,
      "application_type" => application_type(auth.redirect_uri)
    }

    case HTTP.post(metadata["registration_endpoint"], [json: body], [], auth.req) do
      {:ok, status, %{"client_id" => client_id} = response}
      when status in 200..299 and is_binary(client_id) ->
        registered = registered(response, method, issuer)
        {:ok, registered, Auth.put(auth, {:client, issuer}, registered)}

      {:ok, status, response} ->
        {:error, {:registration_failed, status, response}, auth}

      {:error, reason} ->
        {:error, {:registration_failed, reason}, auth}
    end
  end

  # A native client cannot keep a secret, so it registers as a public
  # client when the server takes one; otherwise it asks for the secret
  # method the server supports.
  defp registration_method(metadata) do
    supported = supported_methods(metadata)
    Enum.find(["none" | @secret_methods], "none", &(&1 in supported))
  end

  # RFC 8414 §2: a server that does not list its token endpoint methods
  # supports `client_secret_basic`.
  defp supported_methods(metadata),
    do: List.wrap(metadata["token_endpoint_auth_methods_supported"] || "client_secret_basic")

  # Asking for the refresh token grant (SEP-2207) unless the server says it
  # does not issue refresh tokens.
  defp grant_types(%{"grant_types_supported" => supported}) when is_list(supported),
    do: Enum.filter(@grant_types, &(&1 == "authorization_code" or &1 in supported))

  defp grant_types(_metadata), do: @grant_types

  # SEP-837: a client whose redirect URI is on a loopback host (or a custom
  # scheme) is a native application; one served from a real host is a web
  # application. OpenID servers default to "web" and may refuse a loopback
  # redirect for it, so the client always says which it is.
  @doc false
  def application_type(redirect_uri) do
    case URI.parse(redirect_uri) do
      %URI{scheme: "https", host: host} when host not in ["localhost", "127.0.0.1", "::1"] ->
        "web"

      _ ->
        "native"
    end
  end

  # The server's answer decides the method; one that needs a secret but
  # came without one falls back to a public client.
  defp registered(response, requested, issuer) do
    secret = response["client_secret"]
    method = response["token_endpoint_auth_method"] || requested

    %{
      "client_id" => response["client_id"],
      "client_secret" => secret,
      "token_endpoint_auth_method" =>
        if(method in @secret_methods and not is_binary(secret), do: "none", else: method),
      "issuer" => issuer
    }
  end
end
