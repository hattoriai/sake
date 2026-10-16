defmodule Sake.Auth.Token do
  @moduledoc """
  The token endpoint: the authorization code grant with PKCE, refresh
  token rotation with reuse detection, the client credentials grant for
  machine clients, and the JWT bearer grant (RFC 7523) for JWTs from a
  `Sake.Auth.TrustedIssuer`: an enterprise ID-JAG, or a workload identity
  token.

  The last two issue an access token alone. A machine client asks again
  with its credentials when it needs a new one (RFC 6749 §4.4.3), and a
  JWT grant goes back through its issuer, so that the issuer's policy
  (a person removed from the directory, a revoked workload) applies at
  every renewal rather than only at the first.

  A token request with a DPoP proof (RFC 9449) gets tokens bound to the
  proof's key: `token_type` is `DPoP`, and the access token is accepted
  only with a proof made with the same key. A public client's refresh
  token is bound to it too, so refreshing needs a proof with that key;
  a confidential client's is bound to its credentials already (RFC 9449
  §5), and each refresh binds the new access token to whichever key the
  proof that comes with it shows.
  """
  @behaviour Plug
  import Plug.Conn

  alias Sake.Auth
  alias Sake.Auth.{Authorize, ClientAuth, Config, DPoP, JWTGrant, PKCE, Subject, Tokens}

  @jwt_bearer "urn:ietf:params:oauth:grant-type:jwt-bearer"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{method: "POST"} = conn, _opts) do
    config = Auth.config()
    conn = parse(conn)
    p = conn.body_params

    # A client is authenticated only for a supported grant type: an
    # unsupported or missing grant_type is reported on its own, without
    # requiring client credentials to say so.
    case p["grant_type"] do
      grant_type when is_binary(grant_type) ->
        if grant_type in grant_types(config),
          do: with_proof(conn, config, p),
          else:
            error(
              conn,
              400,
              "unsupported_grant_type",
              "Supported grant types: #{Enum.join(grant_types(config), ", ")}"
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

  @doc false
  # The client credentials grant exists only when the subject module can
  # name a machine client's principal, and the JWT bearer grant only when
  # some issuer is trusted.
  @spec grant_types(Config.t()) :: [String.t()]
  def grant_types(config) do
    Code.ensure_loaded(config.subject)

    ["authorization_code", "refresh_token"] ++
      if(function_exported?(config.subject, :client_principal, 1),
        do: ["client_credentials"],
        else: []
      ) ++
      if config.trusted_issuers == [], do: [], else: [@jwt_bearer]
  end

  # The proof is checked before anything else: before the client is
  # authenticated and before a code or a refresh token is consumed, so a
  # request refused for its nonce leaves them usable for the retry.
  defp with_proof(conn, config, p) do
    case proof(conn, config) do
      {:ok, jkt} ->
        authenticate_and_grant(DPoP.put_nonce(conn, config), config, p, jkt)

      {:error, "use_dpop_nonce", description} ->
        conn |> DPoP.put_nonce(config) |> error(400, "use_dpop_nonce", description)

      {:error, code, description} ->
        error(conn, 400, code, description)
    end
  end

  # A server without DPoP ignores the header and issues bearer tokens
  # (RFC 9449 §5), which a client sees from their `token_type`.
  defp proof(_conn, %Config{dpop: false}), do: {:ok, nil}

  defp proof(conn, config) do
    case DPoP.from_conn(conn) do
      :none ->
        {:ok, nil}

      {:ok, proof} ->
        DPoP.verify(proof,
          htm: "POST",
          htu: [Config.token_url(config)],
          nonce: DPoP.nonce_secret(config)
        )

      {:error, code, description} ->
        {:error, code, description}
    end
  end

  defp authenticate_and_grant(conn, config, p, jkt) do
    case ClientAuth.authenticate(config, conn, p) do
      {:error, :invalid_client} ->
        conn
        |> put_resp_header("www-authenticate", ~s(Basic realm="sake"))
        |> error(401, "invalid_client", "Client authentication failed")

      {:ok, client} ->
        with :ok <- client_grant(client, p["grant_type"]),
             {:ok, response} <- grant(config, client, p, jkt) do
          json(conn, 200, response)
        else
          {:error, code, description} -> error(conn, 400, code, description)
        end
    end
  end

  defp client_grant(client, grant_type) do
    if grant_type in client.grant_types,
      do: :ok,
      else: {:error, "unauthorized_client", "The client may not use the #{grant_type} grant"}
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
           p,
         jkt
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
             family_id: hash,
             jkt: jkt,
             refresh_jkt: refresh_binding(client, jkt)
           })}
        end
    end
  end

  defp grant(_config, _client, %{"grant_type" => "authorization_code"}, _jkt),
    do: {:error, "invalid_request", "code, redirect_uri and code_verifier are required"}

  defp grant(
         config,
         client,
         %{"grant_type" => "refresh_token", "refresh_token" => refresh} = p,
         jkt
       )
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
        with {:ok, attrs} <- rotate(client, record, p, jkt) do
          issued_unless_revoked(config, {module, state}, hash, attrs)
        end
    end
  end

  defp grant(_config, _client, %{"grant_type" => "refresh_token"}, _jkt),
    do: {:error, "invalid_request", "refresh_token is required"}

  # RFC 6749 §4.4: confidential clients only. The host's subject module
  # names the principal the client acts as, or refuses it.
  defp grant(config, client, %{"grant_type" => "client_credentials"} = p, jkt) do
    with :ok <- confidential(client),
         {:ok, principal} <- machine_principal(config, client),
         {:ok, scopes} <- granted_scopes(config, p["scope"], [client.scopes]),
         {:ok, resource} <- target(config, p["resource"]),
         :ok <- resource_allowed(config, principal, resource) do
      {:ok,
       issue_access(config, %{
         client_id: client.id,
         subject_id: nil,
         scopes: scopes,
         resource: resource,
         jkt: jkt
       })}
    end
  end

  defp grant(config, client, %{"grant_type" => @jwt_bearer, "assertion" => assertion} = p, jkt)
       when is_binary(assertion) do
    with {:ok, grant} <- JWTGrant.verify(config, client, assertion),
         {:ok, scopes} <- granted_scopes(config, p["scope"], JWTGrant.scope_limits(client, grant)),
         {:ok, resource} <- JWTGrant.resource(config, grant, p["resource"]),
         :ok <- resource_allowed(config, grant.principal, resource) do
      {:ok,
       issue_access(config, %{
         client_id: client.id,
         subject_id: config.subject.id(grant.principal),
         scopes: scopes,
         resource: resource,
         jkt: jkt
       })}
    end
  end

  defp grant(_config, _client, %{"grant_type" => @jwt_bearer}, _jkt),
    do: {:error, "invalid_request", "assertion is required"}

  defp confidential(%{token_endpoint_auth_method: "none"}),
    do: {:error, "unauthorized_client", "Only a confidential client may use client_credentials"}

  defp confidential(_client), do: :ok

  defp machine_principal(config, client) do
    case Subject.client_principal(config.subject, client) do
      {:ok, principal} -> {:ok, principal}
      :error -> {:error, "unauthorized_client", "The client may not act on its own behalf"}
    end
  end

  defp target(config, resource) do
    case Authorize.resource(config, resource) do
      {:ok, resource} ->
        {:ok, resource}

      :error ->
        {:error, "invalid_target", "The resource is not served by this authorization server"}
    end
  end

  defp resource_allowed(config, principal, resource) do
    if Subject.authorize_resource?(config.subject, principal, resource),
      do: :ok,
      else: {:error, "invalid_grant", "The principal may not use this resource"}
  end

  # The scopes a grant without a person gets: the ones asked for (by
  # default every scope the servers declare), narrowed to what the limits
  # allow. Each limit is a list of scopes (the client's, the issuer's, the
  # grant's own), or nil for none. There is nobody to ask for more, so a
  # request is narrowed rather than refused (RFC 6749 §3.3; the answer's
  # `scope` says what was granted), unless nothing of it is left.
  defp granted_scopes(config, scope, limits) do
    known = config |> Config.scopes() |> Enum.map(&elem(&1, 0))
    limits = Enum.reject(limits, &is_nil/1)

    requested =
      if is_binary(scope) and scope != "", do: Enum.uniq(String.split(scope)), else: known

    granted = Enum.filter(requested, fn s -> Enum.all?(limits, &(s in &1)) end)

    cond do
      requested -- known != [] ->
        {:error, "invalid_scope", "Unknown scope: #{Enum.join(requested -- known, " ")}"}

      granted == [] and requested != [] ->
        {:error, "invalid_scope", "The scope exceeds what this grant allows"}

      true ->
        {:ok, granted}
    end
  end

  defp issue_access(config, attrs) do
    {access, _record} = Tokens.issue_access(config, attrs)

    %{
      "access_token" => access,
      "token_type" => token_type(attrs),
      "expires_in" => config.access_token_ttl,
      "scope" => Enum.join(attrs.scopes, " ")
    }
  end

  defp rotate(client, record, p, jkt) do
    with :ok <- fresh(record),
         true <-
           record.client_id == client.id ||
             {:error, "invalid_grant", "The refresh token belongs to another client"},
         :ok <- same_key(record, jkt),
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
         family_id: record.family_id,
         jkt: jkt,
         refresh_jkt: refresh_binding(client, jkt)
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

  # RFC 9449 §5: a public client's refresh token is bound to its DPoP key,
  # the only thing that tells its holder from a thief; a confidential
  # client's is bound to the client's credentials already.
  defp refresh_binding(%{token_endpoint_auth_method: "none"}, jkt), do: jkt
  defp refresh_binding(_client, _jkt), do: nil

  defp same_key(%{jkt: nil}, _jkt), do: :ok
  defp same_key(%{jkt: jkt}, jkt), do: :ok

  defp same_key(_record, nil),
    do:
      {:error, "invalid_grant", "The refresh token is bound to a DPoP key: send a proof with it"}

  defp same_key(_record, _jkt),
    do: {:error, "invalid_grant", "The refresh token is bound to another DPoP key"}

  defp token_type(%{jkt: jkt}) when is_binary(jkt), do: "DPoP"
  defp token_type(_attrs), do: "Bearer"

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
      "token_type" => token_type(attrs),
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
