defmodule Sake.Auth.TokenGrants do
  @moduledoc false
  # The token endpoint's grants: the authorization code grant with PKCE,
  # the device code grant (RFC 8628 §3.4), refresh token rotation with
  # reuse detection, the client credentials
  # grant for machine clients, and the JWT bearer grant (RFC 7523) for
  # JWTs from a `Sake.Auth.TrustedIssuer`: an enterprise ID-JAG, or a
  # workload identity token.
  #
  # The last two issue an access token alone. A machine client asks again
  # with its credentials when it needs a new one (RFC 6749 §4.4.3), and a
  # JWT grant goes back through its issuer, so that the issuer's policy
  # (a person removed from the directory, a revoked workload) applies at
  # every renewal rather than only at the first.
  #
  # A token request with a DPoP proof (RFC 9449) gets tokens bound to the
  # proof's key: `token_type` is `DPoP`, and the access token is accepted
  # only with a proof made with the same key. A public client's refresh
  # token is bound to it too, so refreshing needs a proof with that key;
  # a confidential client's is bound to its credentials already (RFC 9449
  # §5), and each refresh binds the new access token to whichever key the
  # proof that comes with it shows.
  #
  # Core: `exchange/4` takes the configuration, the request's parameters,
  # the client's credentials and the checked DPoP proof, and never sees
  # the conn; `Sake.Auth.Token` reads the request and renders the answer.
  # Each grant type is one clause of `grant/4`.

  alias Sake.Auth

  alias Sake.Auth.{
    AuthorizationRequest,
    ClientAuth,
    Config,
    DPoP,
    JWTGrant,
    PKCE,
    Subject,
    Tokens
  }

  @jwt_bearer "urn:ietf:params:oauth:grant-type:jwt-bearer"
  @device_code "urn:ietf:params:oauth:grant-type:device_code"

  @type error :: {:error, 400 | 401, String.t(), String.t()}

  @doc false
  # The client credentials grant exists only when the subject module can
  # name a machine client's principal, the JWT bearer grant only when
  # some issuer is trusted, and the device code grant only with `device:`.
  @spec grant_types(Config.t()) :: [String.t()]
  def grant_types(config) do
    Code.ensure_loaded(config.subject)

    ["authorization_code", "refresh_token"] ++
      if(function_exported?(config.subject, :client_principal, 1),
        do: ["client_credentials"],
        else: []
      ) ++
      if(config.trusted_issuers == [], do: [], else: [@jwt_bearer]) ++
      if config.device == false, do: [], else: [@device_code]
  end

  @doc """
  Whether the request's `grant_type` is one this server offers. A client
  is authenticated only for a supported grant type: an unsupported or
  missing grant_type is reported on its own, without requiring client
  credentials to say so, and before the DPoP proof is looked at.
  """
  @spec supported(Config.t(), map()) :: :ok | error()
  def supported(config, p) do
    case p["grant_type"] do
      grant_type when is_binary(grant_type) ->
        if grant_type in grant_types(config),
          do: :ok,
          else:
            {:error, 400, "unsupported_grant_type",
             "Supported grant types: #{Enum.join(grant_types(config), ", ")}"}

      _ ->
        {:error, 400, "invalid_request", "grant_type is required"}
    end
  end

  @doc """
  The request's DPoP proof (the values of its `DPoP` header), checked for
  the token endpoint: `{:ok, nil}` without one, or on a server without
  DPoP, which ignores the header and issues bearer tokens (RFC 9449 §5);
  a client sees that from their `token_type`.

  The proof is checked before anything else: before the client is
  authenticated and before a code or a refresh token is consumed, so a
  request refused for its nonce leaves them usable for the retry.
  """
  @spec proof(Config.t(), [String.t()]) :: {:ok, map() | nil} | {:error, String.t(), String.t()}
  def proof(%Config{dpop: false}, _headers), do: {:ok, nil}

  def proof(config, headers) do
    case DPoP.from_headers(headers) do
      :none ->
        {:ok, nil}

      {:ok, proof} ->
        DPoP.check(proof,
          htm: "POST",
          htu: [Config.token_url(config)],
          nonce: DPoP.nonce_secret(config)
        )

      {:error, code, description} ->
        {:error, code, description}
    end
  end

  @doc """
  Exchanges a grant for tokens: `params` are the token request's
  parameters, `credentials` the client's (`ClientAuth.credentials/1`),
  and `proof` the proof `proof/2` checked, or nil. Returns the token
  response, or the HTTP status, error code and description: 401 for a
  client that does not authenticate, 400 for anything else.

  The proof is recorded as used only once the client is authenticated,
  and before anything is consumed: a request that cannot authenticate a
  client leaves nothing behind.
  """
  @spec exchange(Config.t(), map(), ClientAuth.credentials(), map() | nil) ::
          {:ok, map()} | error()
  def exchange(config, p, credentials, proof) do
    with :ok <- supported(config, p) do
      case ClientAuth.authenticate(config, credentials, p) do
        {:error, :invalid_client} ->
          {:error, 401, "invalid_client", "Client authentication failed"}

        {:ok, client} ->
          authenticated(config, client, p, proof)
      end
    end
  end

  defp authenticated(config, client, p, proof) do
    jkt = proof && proof.jkt

    with :ok <- recorded(proof),
         :ok <- client_grant(client, p["grant_type"]),
         :ok <- proof_required(config, client, jkt),
         {:ok, response} <- grant(config, client, p, jkt) do
      {:ok, response}
    else
      {:error, code, description} -> {:error, 400, code, description}
    end
  end

  defp recorded(nil), do: :ok
  defp recorded(checked), do: DPoP.record(checked)

  # A server with `dpop: [required: true]`, and a client registered with
  # `dpop_bound_access_tokens` (RFC 9449 §5.2: "the authorization server
  # MUST reject token requests from this client that do not contain the
  # DPoP header"), get bound tokens or none, on every grant. Neither RFC
  # 9449 nor RFC 6749 names the error for a proof that is missing; it is
  # `invalid_dpop_proof`, the code §5 gives a token request whose proof
  # does not do, so that a client sees it is about DPoP. The check runs
  # before the grant, so a code or refresh token is not spent on it.
  defp proof_required(_config, _client, jkt) when is_binary(jkt), do: :ok

  defp proof_required(config, client, nil) do
    cond do
      Config.dpop_required?(config) ->
        {:error, "invalid_dpop_proof", "This server issues DPoP-bound tokens only: send a proof"}

      client.dpop_bound_access_tokens and config.dpop == false ->
        {:error, "invalid_client", "The client requires DPoP, which this server does not offer"}

      client.dpop_bound_access_tokens ->
        {:error, "invalid_dpop_proof", "The client's tokens must be DPoP-bound: send a proof"}

      true ->
        :ok
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
        with :ok <- check_code(record, client, uri, verifier, p["resource"]),
             :ok <- code_key(record, jkt) do
          issue_for_code(config, {module, state}, hash, %{
            client_id: client.id,
            subject_id: record.subject_id,
            scopes: record.scopes,
            resource: record.resource,
            family_id: hash,
            jkt: jkt,
            refresh_jkt: refresh_binding(client, jkt)
          })
        end
    end
  end

  defp grant(_config, _client, %{"grant_type" => "authorization_code"}, _jkt),
    do: {:error, "invalid_request", "code, redirect_uri and code_verifier are required"}

  # RFC 8628 §3.5: the client polls with the device code until the
  # person decides. The store answers each poll atomically and records
  # it, so a client that polls faster than the interval is told to slow
  # down, and an approved grant is issued once; the device code used
  # again after that revokes every token issued for it, as a code does.
  defp grant(config, client, %{"grant_type" => @device_code, "device_code" => code} = p, jkt)
       when is_binary(code) do
    {module, state} = Auth.store(config)
    hash = Tokens.hash(code)

    case module.poll_device_grant(state, hash, client.id, DateTime.utc_now()) do
      {:approved, record} ->
        with :ok <- same_resource(record, p["resource"]) do
          issue_for_device(config, {module, state}, hash, %{
            client_id: client.id,
            subject_id: record.subject_id,
            scopes: record.scopes,
            resource: record.resource,
            family_id: hash,
            jkt: jkt,
            refresh_jkt: refresh_binding(client, jkt)
          })
        end

      :pending ->
        {:error, "authorization_pending", "The person has not decided yet"}

      :slow_down ->
        {:error, "slow_down", "Polled too often: wait longer between requests"}

      :denied ->
        {:error, "access_denied", "The person denied the request"}

      :expired ->
        {:error, "expired_token", "The device code has expired"}

      :used ->
        module.revoke_family(state, hash)
        {:error, "invalid_grant", "The device code was already used"}

      :error ->
        {:error, "invalid_grant", "The device code is invalid"}
    end
  end

  defp grant(_config, _client, %{"grant_type" => @device_code}, _jkt),
    do: {:error, "invalid_request", "device_code is required"}

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
        with {:ok, attrs} <- rotate(client, record, p, jkt),
             {:ok, scopes} <- still_authorized(config, {module, state}, client, record, attrs) do
          issue_rotated(config, {module, state}, hash, %{attrs | scopes: scopes})
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
         :ok <- resource_allowed(config, principal, resource),
         {:ok, scopes} <- principal_scopes(config, principal, resource, scopes) do
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
         :ok <- resource_allowed(config, grant.principal, resource),
         {:ok, scopes} <- principal_scopes(config, grant.principal, resource, scopes) do
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
    case AuthorizationRequest.resource(config, resource) do
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

  # The scopes narrowed to those the principal may hold for the resource
  # (`c:Sake.Auth.Subject.scopes_for/2`), refused when none of a request
  # for some is left, as `granted_scopes/3` refuses.
  defp principal_scopes(config, principal, resource, scopes) do
    case Subject.permitted_scopes(config.subject, principal, resource, scopes) do
      [] when scopes != [] ->
        {:error, "invalid_scope", "The scope exceeds what this grant allows"}

      permitted ->
        {:ok, permitted}
    end
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
         scopes = allowed_scopes(scopes, client),
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

  # A reuse of the refresh token racing this rotation revokes the family;
  # the store refuses the new pair then, atomically with that revocation
  # (`put_rotated_tokens/3`), so the race never leaves a live pair behind.
  defp issue_rotated(config, {module, state}, hash, attrs) do
    {access, refresh, %{access: a, refresh: r}} = Tokens.new_pair(config, attrs)

    case module.put_rotated_tokens(state, hash, [a, r]) do
      :ok -> {:ok, response(config, attrs, access, refresh)}
      :revoked -> {:error, "invalid_grant", "The refresh token is expired or revoked"}
    end
  end

  # RFC 6749 §4.1.2: a code used twice revokes every token issued for it.
  # A replay racing the request that consumed the code may revoke the
  # family before this request stores its pair; the store refuses the pair
  # then, atomically with that revocation (`put_code_tokens/3`), so the
  # replay never leaves a live pair behind.
  defp issue_for_code(config, {module, state}, hash, attrs) do
    {access, refresh, %{access: a, refresh: r}} = Tokens.new_pair(config, attrs)

    case module.put_code_tokens(state, hash, [a, r]) do
      :ok -> {:ok, response(config, attrs, access, refresh)}
      :revoked -> {:error, "invalid_grant", "The code is invalid, expired or already used"}
    end
  end

  # The same fence for a device grant (`put_device_tokens/3`): a replay
  # of the device code racing this request never leaves a live pair.
  defp issue_for_device(config, {module, state}, hash, attrs) do
    {access, refresh, %{access: a, refresh: r}} = Tokens.new_pair(config, attrs)

    case module.put_device_tokens(state, hash, [a, r]) do
      :ok -> {:ok, response(config, attrs, access, refresh)}
      :revoked -> {:error, "invalid_grant", "The device code was already used"}
    end
  end

  defp same_resource(_record, nil), do: :ok
  defp same_resource(%{resource: resource}, resource), do: :ok
  defp same_resource(_record, _resource), do: {:error, "invalid_grant", "resource does not match"}

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

  # RFC 9449 §10: a code bound to a DPoP key (by `dpop_jkt`, or the proof
  # of the pushed request it came from) is redeemed only with a proof
  # made with that key. The code is spent either way, as it is on a
  # wrong code_verifier.
  defp code_key(%{dpop_jkt: nil}, _jkt), do: :ok
  defp code_key(%{dpop_jkt: jkt}, jkt), do: :ok

  defp code_key(_record, nil),
    do: {:error, "invalid_grant", "The code is bound to a DPoP key: send a proof with it"}

  defp code_key(_record, _jkt),
    do: {:error, "invalid_grant", "The code is bound to another DPoP key"}

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

  # A refresh renews the grant only while the person may still have it:
  # their account still loads, `authorize_resource?/2` still allows the
  # resource (someone removed from a tenant, say), and `scopes_for/2`
  # still allows some of the scopes renewed, which are narrowed to those.
  # Otherwise the whole family is revoked, its live access token included,
  # and the client has to send the person through authorization again.
  # Returns the scopes to renew.
  defp still_authorized(config, {module, state}, client, record, attrs) do
    with {:ok, principal} <- refresh_principal(config, client, record),
         true <- Subject.authorize_resource?(config.subject, principal, record.resource),
         scopes =
           Subject.permitted_scopes(config.subject, principal, record.resource, attrs.scopes),
         true <- scopes != [] or attrs.scopes == [] do
      {:ok, scopes}
    else
      _ ->
        module.revoke_family(state, record.family_id)
        {:error, "invalid_grant", "The grant is no longer authorized"}
    end
  end

  defp refresh_principal(config, client, %{subject_id: nil}),
    do: Subject.client_principal(config.subject, client)

  defp refresh_principal(config, _client, %{subject_id: id}), do: config.subject.fetch(id)

  # The scopes the client may still request: a client whose allowed scopes
  # were narrowed since the grant renews it with only those.
  defp allowed_scopes(scopes, %{scopes: nil}), do: scopes
  defp allowed_scopes(scopes, %{scopes: allowed}), do: Enum.filter(scopes, &(&1 in allowed))

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

  defp response(config, attrs, access, refresh) do
    %{
      "access_token" => access,
      "token_type" => token_type(attrs),
      "expires_in" => config.access_token_ttl,
      "refresh_token" => refresh,
      "scope" => Enum.join(attrs.scopes, " ")
    }
  end
end
