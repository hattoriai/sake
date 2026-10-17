defmodule Sake.Auth.PAR do
  @moduledoc false
  # Pushed authorization requests (RFC 9126): the client sends its
  # authorization request straight to the authorization server,
  # authenticated as at the token endpoint, and gets a `request_uri`
  # back; the browser then carries only that and the `client_id` to the
  # authorize endpoint. The parameters cannot be tampered with or leak
  # on the way, and only the client itself can start a request.
  #
  # A pushed request is validated as one sent to the authorize endpoint
  # (`AuthorizationRequest.validate/3`, `extra` included), and stored by
  # the hash of its `request_uri`, which is good once, for `par:`'s
  # `expires_in` seconds, and for its client alone. The authorize
  # endpoint takes it (`take/3`) and goes on as for a request sent to it
  # directly: `Grant.decide/4`.
  #
  # A push with a DPoP proof (or a `dpop_jkt` parameter, RFC 9449 §10)
  # records the key's thumbprint in the request's `extra`, so the code,
  # and then its tokens, can only be redeemed with that key.
  #
  # Core: it takes the configuration, the parameters, the client's
  # credentials and the checked DPoP proof, and never sees the conn;
  # `Sake.Auth.PushedAuthorization` is the adapter, and
  # `Sake.Auth.Authorize` takes the request.

  alias Sake.Auth

  alias Sake.Auth.{
    AuthorizationRequest,
    Client,
    ClientAuth,
    Config,
    DPoP,
    PushedRequest,
    Redirect,
    Tokens
  }

  @prefix "urn:ietf:params:oauth:request_uri:"

  @doc """
  The push's DPoP proof (the values of its `DPoP` header), checked for
  the pushed authorization request endpoint, as `TokenGrants.proof/2`
  checks the token endpoint's: `{:ok, nil}` without one or without DPoP.
  """
  @spec proof(Config.t(), [String.t()]) ::
          {:ok, DPoP.checked() | nil} | {:error, String.t(), String.t()}
  def proof(%Config{dpop: false}, _headers), do: {:ok, nil}

  def proof(config, headers) do
    case DPoP.from_headers(headers) do
      :none ->
        {:ok, nil}

      {:ok, proof} ->
        DPoP.check(proof,
          htm: "POST",
          htu: [Config.par_url(config)],
          nonce: DPoP.nonce_secret(config)
        )

      {:error, code, description} ->
        {:error, code, description}
    end
  end

  @doc """
  A pushed authorization request (RFC 9126 §2.1): authenticates the
  client as the token endpoint does (a public client by its
  `client_id`), records the proof as used, then `push/4`. Returns the
  response, or the HTTP status, error code and description.
  """
  @spec request(Config.t(), map(), ClientAuth.credentials(), DPoP.checked() | nil) ::
          {:ok, map()} | {:error, 400 | 401, String.t(), String.t()}
  def request(config, p, credentials, proof) do
    case ClientAuth.authenticate(config, credentials, p) do
      {:ok, client} ->
        with :ok <- recorded(proof),
             {:ok, response} <- push(config, client, p, proof && proof.jkt) do
          {:ok, response}
        else
          {:error, code, description} -> {:error, 400, code, description}
        end

      {:error, :invalid_client} ->
        {:error, 401, "invalid_client", "Client authentication failed"}
    end
  end

  defp recorded(nil), do: :ok
  defp recorded(checked), do: DPoP.record(checked)

  @doc """
  Pushes an authorization request from an authenticated `client`:
  validates `params` as the authorize endpoint would, stores the request
  and returns the response (RFC 9126 §2.2), with its `request_uri` and
  `expires_in`. `jkt` is the thumbprint of the push's DPoP proof key, or
  nil; the code will be bound to it.
  """
  @spec push(Config.t(), Client.t(), map(), String.t() | nil) ::
          {:ok, %{String.t() => String.t() | pos_integer()}} | {:error, String.t(), String.t()}
  def push(config, client, p, jkt \\ nil) do
    with :ok <- pushable(client, p),
         {:ok, request} <- AuthorizationRequest.validate(config, client, p),
         {:ok, request} <- bind(request, jkt) do
      {module, state} = Auth.store(config)
      request_uri = @prefix <> Tokens.generate()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      :ok =
        module.put_pushed_request(state, %PushedRequest{
          hash: Tokens.hash(request_uri),
          client_id: client.id,
          redirect_uri: request.redirect_uri,
          state: request.state,
          code_challenge: request.code_challenge,
          scopes: request.scopes,
          resource: request.resource,
          extra: request.extra,
          expires_at: DateTime.add(now, config.par.expires_in),
          inserted_at: now
        })

      {:ok, %{"request_uri" => request_uri, "expires_in" => config.par.expires_in}}
    end
  end

  # RFC 9126 §2.1: a pushed request cannot name another pushed request,
  # and Sake takes no request objects (RFC 9101). The client_id, when
  # the request has one, is the client that authenticated, and the
  # redirect URI one it registered: an error here goes back to the
  # client, which sent the request itself.
  defp pushable(client, p) do
    cond do
      Map.has_key?(p, "request_uri") ->
        {:error, "invalid_request", "A pushed request must not carry a request_uri"}

      Map.has_key?(p, "request") ->
        {:error, "request_not_supported", "Request objects are not supported"}

      p["client_id"] not in [nil, client.id] ->
        {:error, "invalid_request", "client_id is not the authenticated client"}

      not (is_binary(p["redirect_uri"]) and
               Redirect.matches?(client.redirect_uris, p["redirect_uri"])) ->
        {:error, "invalid_request", "redirect_uri is not one the client registered"}

      true ->
        :ok
    end
  end

  # RFC 9449 §10.1: a push with a proof binds the code to the proof's
  # key; with `dpop_jkt` as well, the two must be the same key.
  defp bind(request, nil), do: {:ok, request}

  defp bind(%{extra: extra} = request, jkt) do
    if extra["dpop_jkt"] in [nil, jkt],
      do: {:ok, %{request | extra: Map.put(extra, "dpop_jkt", jkt)}},
      else: {:error, "invalid_dpop_proof", "dpop_jkt is not the DPoP proof's key"}
  end

  @doc """
  Takes the pushed request `request_uri` names, for the authorize
  endpoint's `client_id`: once, while it has not expired, and only for
  the client that pushed it. Returns the client and the request, which
  goes on as one sent to the authorize endpoint; an error is never sent
  to a redirect URI, as `AuthorizationRequest.client/3`'s are not.
  """
  @spec take(Config.t(), term(), term()) ::
          {:ok, Client.t(), AuthorizationRequest.t()}
          | {:error, :request_uri | :client_mismatch | :unknown_client | :redirect_uri}
          | {:error, :client, term()}
  def take(config, client_id, request_uri) do
    with {:ok, pushed} <- consume(config, request_uri),
         :ok <- same_client(pushed, client_id),
         {:ok, client} <- AuthorizationRequest.client(config, client_id, pushed.redirect_uri) do
      {:ok, client,
       %AuthorizationRequest{
         client_id: pushed.client_id,
         redirect_uri: pushed.redirect_uri,
         state: pushed.state,
         code_challenge: pushed.code_challenge,
         scopes: pushed.scopes,
         resource: pushed.resource,
         extra: pushed.extra || %{}
       }}
    end
  end

  defp same_client(%{client_id: client_id}, client_id), do: :ok
  defp same_client(_pushed, _client_id), do: {:error, :client_mismatch}

  # Taken before anything else is checked: a request_uri is spent once
  # it is presented, whatever comes of it.
  defp consume(config, @prefix <> _ = request_uri) do
    {module, state} = Auth.store(config)

    with {:ok, pushed} <- module.consume_pushed_request(state, Tokens.hash(request_uri)),
         :gt <- DateTime.compare(pushed.expires_at, DateTime.utc_now()) do
      {:ok, pushed}
    else
      _ -> {:error, :request_uri}
    end
  end

  defp consume(_config, _request_uri), do: {:error, :request_uri}

  @doc """
  Whether `client` may send an authorization request that was not
  pushed: not with `par: [required: true]`, nor when it registered with
  `require_pushed_authorization_requests`. The error is for its
  redirect URI.
  """
  @spec direct(Config.t(), Client.t()) :: :ok | {:error, String.t(), String.t()}
  def direct(config, client) do
    if Config.par_required?(config, client),
      do:
        {:error, "invalid_request",
         "Push the authorization request first: pushed authorization requests are required"},
      else: :ok
  end
end
