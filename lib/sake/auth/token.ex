defmodule Sake.Auth.Token do
  @moduledoc """
  The token endpoint: the authorization code grant with PKCE, and refresh
  token rotation with reuse detection.
  """
  @behaviour Plug
  import Plug.Conn

  alias Sake.Auth
  alias Sake.Auth.{ClientAuth, PKCE, Tokens}

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{method: "POST"} = conn, _opts) do
    config = Auth.config()
    conn = parse(conn)
    p = conn.body_params

    # A client is authenticated only for the two supported grant types: an
    # unsupported or missing grant_type is reported on its own, without
    # requiring client credentials to say so.
    case p["grant_type"] do
      grant_type when grant_type in ["authorization_code", "refresh_token"] ->
        authenticate_and_grant(conn, config, p)

      grant_type when is_binary(grant_type) ->
        error(
          conn,
          400,
          "unsupported_grant_type",
          "Only authorization_code and refresh_token are supported"
        )

      _ ->
        error(conn, 400, "invalid_request", "grant_type is required")
    end
  end

  def call(conn, _opts) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
    |> send_resp(405, "")
  end

  defp authenticate_and_grant(conn, config, p) do
    case ClientAuth.authenticate(config, conn, p) do
      {:error, :invalid_client} ->
        conn
        |> put_resp_header("www-authenticate", ~s(Basic realm="sake"))
        |> error(401, "invalid_client", "Client authentication failed")

      {:ok, client} ->
        case grant(config, client, p) do
          {:ok, response} -> json(conn, 200, response)
          {:error, code, description} -> error(conn, 400, code, description)
        end
    end
  end

  defp grant(
         config,
         client,
         %{
           "grant_type" => "authorization_code",
           "code" => code,
           "redirect_uri" => uri,
           "code_verifier" => verifier
         } =
           p
       )
       when is_binary(code) and is_binary(uri) and is_binary(verifier) do
    {module, state} = Auth.store(config)
    hash = Tokens.hash(code)

    case module.consume_code(state, hash) do
      :error ->
        module.revoke_family(state, hash)
        {:error, "invalid_grant", "The code is invalid, expired or already used"}

      {:ok, record} ->
        with :ok <- check_code(record, client, uri, verifier, p["resource"]) do
          {:ok,
           issue(config, %{
             client_id: client.id,
             subject_id: record.subject_id,
             scopes: record.scopes,
             resource: record.resource,
             family_id: hash
           })}
        end
    end
  end

  defp grant(_config, _client, %{"grant_type" => "authorization_code"}),
    do: {:error, "invalid_request", "code, redirect_uri and code_verifier are required"}

  defp grant(config, client, %{"grant_type" => "refresh_token", "refresh_token" => refresh} = p)
       when is_binary(refresh) do
    {module, state} = Auth.store(config)
    hash = Tokens.hash(refresh)

    case module.consume_refresh(state, hash) do
      :error ->
        {:error, "invalid_grant", "Unknown refresh token"}

      {:error, :used, record} ->
        module.revoke_family(state, record.family_id)
        {:error, "invalid_grant", "The refresh token was already used"}

      {:ok, record} ->
        with {:ok, attrs} <- rotate(client, record, p) do
          issued_unless_revoked(config, {module, state}, hash, attrs)
        end
    end
  end

  defp grant(_config, _client, %{"grant_type" => "refresh_token"}),
    do: {:error, "invalid_request", "refresh_token is required"}

  defp rotate(client, record, p) do
    with :ok <- fresh(record),
         true <-
           record.client_id == client.id ||
             {:error, "invalid_grant", "The refresh token belongs to another client"},
         {:ok, scopes} <- narrowed(record.scopes, p["scope"]),
         true <-
           p["resource"] in [nil, record.resource] ||
             {:error, "invalid_grant", "resource does not match"} do
      {:ok,
       %{
         client_id: client.id,
         subject_id: record.subject_id,
         scopes: scopes,
         resource: record.resource,
         family_id: record.family_id
       }}
    else
      {:error, code, description} -> {:error, code, description}
    end
  end

  # The store may only be able to revoke the rows that exist when
  # `revoke_family/2` runs (a plain `UPDATE ... WHERE family_id = ?`, for
  # instance): it cannot reach back and revoke a pair inserted after a
  # concurrent request already swept the family. So the endpoint checks for
  # itself, after inserting: if the token it just consumed shows revoked
  # now, a concurrent reuse raced this request, and the new pair it just
  # created must be revoked too, and denied, rather than handed out.
  defp issued_unless_revoked(config, {module, state}, hash, attrs) do
    response = issue(config, attrs)

    case module.get_token(state, :refresh, hash) do
      {:ok, %{revoked_at: at}} when not is_nil(at) ->
        module.revoke_family(state, attrs.family_id)
        {:error, "invalid_grant", "The refresh token was already used"}

      _ ->
        {:ok, response}
    end
  end

  defp check_code(record, client, uri, verifier, resource) do
    cond do
      DateTime.compare(record.expires_at, DateTime.utc_now()) != :gt ->
        {:error, "invalid_grant", "The code has expired"}

      record.client_id != client.id ->
        {:error, "invalid_grant", "The code was issued to another client"}

      record.redirect_uri != uri ->
        {:error, "invalid_grant", "redirect_uri does not match"}

      not PKCE.verify(record.code_challenge, verifier) ->
        {:error, "invalid_grant", "code_verifier does not match"}

      is_binary(resource) and resource != record.resource ->
        {:error, "invalid_grant", "resource does not match"}

      true ->
        :ok
    end
  end

  defp fresh(record) do
    if Tokens.valid?(record, DateTime.utc_now()),
      do: :ok,
      else: {:error, "invalid_grant", "The refresh token is expired or revoked"}
  end

  defp narrowed(granted, nil), do: {:ok, granted}

  defp narrowed(granted, scope) when is_binary(scope) do
    requested = String.split(scope)

    if requested -- granted == [],
      do: {:ok, requested},
      else: {:error, "invalid_scope", "The scope exceeds what was granted"}
  end

  defp issue(config, attrs) do
    {access, refresh, _} = Tokens.issue_pair(config, attrs)

    %{
      "access_token" => access,
      "token_type" => "Bearer",
      "expires_in" => config.access_token_ttl,
      "refresh_token" => refresh,
      "scope" => Enum.join(attrs.scopes, " ")
    }
  end

  @doc false
  def parse(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} ->
        Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:urlencoded], pass: ["*/*"]))

      _ ->
        conn
    end
  end

  @doc false
  def json(conn, status, body) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(body))
  end

  @doc false
  def error(conn, status, code, description),
    do: json(conn, status, %{"error" => code, "error_description" => description})
end
