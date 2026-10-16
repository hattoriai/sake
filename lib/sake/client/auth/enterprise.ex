defmodule Sake.Client.Auth.Enterprise do
  @moduledoc false
  # Enterprise-managed authorization from the client's side: the person's
  # ID token (from the host's own single sign-on) is exchanged at the
  # enterprise identity provider for an Identity Assertion JWT
  # Authorization Grant (RFC 8693 token exchange), which the MCP
  # authorization server then takes as a JWT bearer grant.

  alias Sake.Client.Auth.{Discovery, Grant, HTTP}

  @token_exchange "urn:ietf:params:oauth:grant-type:token-exchange"
  @id_jag "urn:ietf:params:oauth:token-type:id-jag"
  @id_token "urn:ietf:params:oauth:token-type:id_token"

  @doc """
  Exchanges `id_token` at the identity provider for an ID-JAG for
  `server`: its issuer as the `audience` and its resource as the
  `resource`, as the profile asks.
  """
  @spec exchange(map(), String.t(), map(), [String.t()], keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def exchange(idp, id_token, server, scopes, req) do
    with {:ok, endpoint, methods} <- token_endpoint(idp, req) do
      params =
        [
          grant_type: @token_exchange,
          requested_token_type: @id_jag,
          audience: server.issuer,
          resource: server.resource,
          subject_token: id_token,
          subject_token_type: @id_token
        ] ++ if(scopes == [], do: [], else: [scope: Enum.join(scopes, " ")])

      {params, headers} = Grant.authenticate(params, registration(idp, methods))

      case HTTP.post(endpoint, [form: params], headers, req) do
        {:ok, 200, %{"access_token" => jag, "issued_token_type" => @id_jag}}
        when is_binary(jag) ->
          {:ok, jag}

        {:ok, status, body} ->
          {:error, {:token_exchange_failed, status, body}}

        {:error, reason} ->
          {:error, {:token_exchange_failed, reason}}
      end
    end
  end

  defp token_endpoint(%{token_endpoint: endpoint}, _req) when is_binary(endpoint),
    do: {:ok, endpoint, nil}

  defp token_endpoint(%{issuer: issuer}, req) do
    case Discovery.issuer_metadata(issuer, req) do
      {:ok, %{"token_endpoint" => endpoint} = metadata} when is_binary(endpoint) ->
        {:ok, endpoint, metadata["token_endpoint_auth_methods_supported"]}

      {:ok, _metadata} ->
        {:error, {:token_exchange_failed, :no_token_endpoint}}

      {:error, reason} ->
        {:error, {:token_exchange_failed, reason}}
    end
  end

  # The client's credentials at the identity provider, sent the way its
  # metadata says it takes them (RFC 8414 §2: `client_secret_basic` when
  # it does not say).
  defp registration(idp, methods) do
    method =
      cond do
        idp[:token_endpoint_auth_method] ->
          idp.token_endpoint_auth_method

        not is_binary(idp[:client_secret]) ->
          "none"

        "client_secret_basic" in List.wrap(methods || "client_secret_basic") ->
          "client_secret_basic"

        true ->
          "client_secret_post"
      end

    %{
      "client_id" => idp[:client_id],
      "client_secret" => idp[:client_secret],
      "token_endpoint_auth_method" => method
    }
  end
end
