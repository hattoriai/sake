defmodule Sake.Client.Auth do
  @moduledoc """
  The MCP authorization flow, run by `Sake.Client` itself. Turn it on with
  `auth:` on `Sake.Client.connect/2`:

      {:ok, session} =
        Sake.Client.connect("https://mcp.example.com/mcp",
          auth: [authorize: &Sake.Client.Auth.Browser.authorize/1]
        )

  On a 401 the client discovers the authorization server (RFC 9728, then
  RFC 8414 or OpenID Connect Discovery), registers or identifies itself,
  sends the person to the authorization endpoint (PKCE with S256, a
  `state`, the RFC 8707 `resource`), checks the answer (`state`, and the
  RFC 9207 `iss`), exchanges the code for a token, and retries the
  request with it. From then on every request carries the token; an
  expired one is refreshed, a 401 tries the refresh token before the whole
  flow, and a 403 `insufficient_scope` asks again for the union of the
  scopes requested so far and the challenged ones (step-up), at most
  twice for one request.

  Options:

    * `:authorize` — the interactive step: a function that receives the
      authorization URL and returns `{:ok, params}`, the query parameters
      the authorization server sent to the redirect URI (`"code"`,
      `"state"`, `"iss"`, or `"error"`), or `{:error, reason}`. Default
      `Sake.Client.Auth.Browser.authorize/1`; `Sake.Client.Auth.Headless.authorize/1`
      is the one for an authorization server that approves without a
      person.
    * `:redirect_uri` — where the authorization server sends the answer.
      Default `"http://127.0.0.1:33418/callback"`, a loopback address
      `Sake.Client.Auth.Browser` listens on.
    * `:client_id`, `:client_secret` — pre-registered credentials, used
      before anything else. `:issuer` names the authorization server they
      belong to; without it they are bound to the first one they are used
      with, and never offered to another. `:token_endpoint_auth_method`
      overrides the method chosen from the server's metadata.
    * `:client_metadata_url` — the HTTPS URL of the client's own Client ID
      Metadata Document, used as the `client_id` when the authorization
      server supports them. Its `redirect_uris` must include
      `:redirect_uri`.
    * `:client_name` — the name a dynamic registration (RFC 7591) gives;
      default the `client_info` name.
    * `:store` — `{module, arg}`, a `Sake.Client.Auth.Store` that keeps
      tokens and dynamic registrations across sessions. Without one, they
      live in the session only.

  Without `auth:`, a 401 is returned as
  `{:error, {:unauthorized, %Sake.Client.Challenge{}}}` and the caller
  handles it. A failure inside the flow is `{:error, {:auth, reason}}`.
  """

  alias Sake.Client.Auth.{Browser, Discovery, Grant, Registration}
  alias Sake.Client.Challenge

  @type t :: %__MODULE__{}

  @redirect_uri "http://127.0.0.1:33418/callback"

  # A token this close to its expiry is refreshed before it is sent, so it
  # does not expire on the way.
  @expiry_margin 30

  defstruct [
    :url,
    :authorize,
    :redirect_uri,
    :client_id,
    :client_secret,
    :token_endpoint_auth_method,
    :client_issuer,
    :client_metadata_url,
    :client_name,
    :store,
    :token,
    clients: %{},
    req: []
  ]

  @doc false
  @spec new(String.t(), keyword(), keyword()) :: t()
  def new(url, opts, defaults) do
    authorize = opts[:authorize] || (&Browser.authorize/1)

    unless is_function(authorize, 1),
      do: raise(ArgumentError, "auth: :authorize must be a function of one argument")

    auth = %__MODULE__{
      url: Discovery.canonical(url),
      authorize: authorize,
      redirect_uri: opts[:redirect_uri] || @redirect_uri,
      client_id: opts[:client_id],
      client_secret: opts[:client_secret],
      token_endpoint_auth_method: opts[:token_endpoint_auth_method],
      client_issuer: opts[:issuer],
      client_metadata_url: metadata_url(opts[:client_metadata_url]),
      client_name: opts[:client_name] || defaults[:client_name] || "Sake",
      store: opts[:store],
      req: defaults[:req] || []
    }

    %{auth | token: fetch(auth, {:token, auth.url})}
  end

  # draft-ietf-oauth-client-id-metadata-document: an https URL with a path.
  defp metadata_url(nil), do: nil

  defp metadata_url(url) do
    if Sake.Auth.CIMD.url?(url),
      do: url,
      else: raise(ArgumentError, "auth: :client_metadata_url must be an https URL with a path")
  end

  @doc false
  @spec headers(t() | nil, [{String.t(), String.t()}]) :: [{String.t(), String.t()}]
  def headers(%__MODULE__{token: %{"access_token" => token}}, headers) do
    [
      {"authorization", "Bearer " <> token}
      | Enum.reject(headers, fn {name, _} -> String.downcase(name) == "authorization" end)
    ]
  end

  def headers(_auth, headers), do: headers

  # ---- what Sake.Client calls

  @doc false
  @spec fresh(t()) :: t()
  def fresh(%__MODULE__{token: %{"expires_at" => at, "refresh_token" => r} = token} = auth)
      when is_integer(at) and is_binary(r) do
    if System.system_time(:second) < at - @expiry_margin do
      auth
    else
      case refresh(auth, token, token["token_endpoint"]) do
        {:ok, auth} -> auth
        {:error, auth} -> auth
      end
    end
  end

  def fresh(auth), do: auth

  @doc false
  @spec unauthorized(t(), Challenge.t(), boolean()) :: {:ok, t()} | {:error, term(), t()}
  def unauthorized(auth, challenge, refresh?) do
    case Discovery.discover(auth.url, challenge, auth.client_issuer, auth.req) do
      {:ok, server} ->
        case maybe_refresh(auth, server, refresh?) do
          {:ok, auth} -> {:ok, auth}
          {:error, auth} -> authorize(auth, server, scopes(auth, server, challenge))
        end

      {:error, reason} ->
        {:error, reason, auth}
    end
  end

  @doc false
  @spec insufficient_scope(t(), Challenge.t()) :: {:ok, t()} | {:error, term(), t()} | :exhausted
  def insufficient_scope(auth, %Challenge{scope: challenged} = challenge) do
    # Asking again for scopes the token already has would only end in the
    # same 403: the server wants something the authorization server will
    # not grant, and that is the caller's answer.
    if challenged -- granted(auth.token) == [] do
      :exhausted
    else
      case Discovery.discover(auth.url, challenge, auth.client_issuer, auth.req) do
        {:ok, server} ->
          authorize(auth, server, union(requested(auth.token), challenged, server.metadata))

        {:error, reason} ->
          {:error, reason, auth}
      end
    end
  end

  # ---- scopes

  # The scopes of a first authorization, by the specification's rule: the
  # challenge's `scope` when it has one, else every scope in the resource
  # metadata's `scopes_supported`, else none (the `scope` parameter is
  # omitted).
  @doc false
  @spec select_scopes(Challenge.t() | nil, map()) :: [String.t()]
  def select_scopes(%Challenge{scope: [_ | _] = scopes}, _server), do: scopes
  def select_scopes(_challenge, %{scopes_supported: [_ | _] = scopes}), do: scopes
  def select_scopes(_challenge, _server), do: []

  # Re-authorizing for the same resource keeps the scopes asked for before,
  # so a new token does not lose what the old one could do.
  defp scopes(auth, server, challenge) do
    previous =
      if auth.token && auth.token["resource"] == server.resource,
        do: requested(auth.token),
        else: []

    union(previous, select_scopes(challenge, server), server.metadata)
  end

  # `offline_access` asks for a refresh token (SEP-2207), and only from a
  # server that lists it; it is added to a non-empty request only, since
  # on its own it would replace the server's default scopes.
  @doc false
  @spec union([String.t()], [String.t()], map()) :: [String.t()]
  def union(previous, scopes, metadata) do
    scopes = Enum.uniq((previous -- ["offline_access"]) ++ scopes)

    if scopes != [] and "offline_access" in List.wrap(metadata["scopes_supported"]),
      do: scopes ++ ["offline_access"],
      else: scopes
  end

  defp granted(%{"scopes" => scopes}), do: scopes
  defp granted(_token), do: []

  defp requested(%{"requested_scopes" => scopes}), do: scopes
  defp requested(_token), do: []

  # ---- the flow

  defp authorize(auth, server, scopes) do
    case Registration.client(auth, server) do
      {:ok, registration, auth} ->
        {url, request} = Grant.request(server, registration, auth.redirect_uri, scopes)

        with {:ok, params} <- interact(auth.authorize, url),
             {:ok, code} <- Grant.callback(params, request),
             {:ok, body} <- Grant.exchange(server, registration, request, code, auth.req) do
          {:ok, put(auth, {:token, auth.url}, token(body, server, registration, scopes))}
        else
          {:error, reason} -> {:error, reason, auth}
        end

      {:error, reason, auth} ->
        {:error, reason, auth}
    end
  end

  defp interact(authorize, url) do
    case authorize.(url) do
      {:ok, params} when is_map(params) -> {:ok, params}
      {:error, reason} -> {:error, {:authorize, reason}}
      other -> {:error, {:authorize, other}}
    end
  end

  # The refresh token is only used with the authorization server and for
  # the resource it was issued for; after a move to another server the
  # whole flow runs against the new one.
  defp maybe_refresh(%__MODULE__{token: %{"refresh_token" => r} = token} = auth, server, true)
       when is_binary(r) do
    if token["issuer"] == server.issuer and token["resource"] == server.resource,
      do: refresh(auth, token, server.metadata["token_endpoint"]),
      else: {:error, auth}
  end

  defp maybe_refresh(auth, _server, _refresh?), do: {:error, auth}

  # A refresh token that failed once is dropped: the next 401 runs the
  # whole flow instead of trying it again.
  defp refresh(auth, token, endpoint) do
    with %{} = registration <- Registration.for_token(auth, token),
         {:ok, body} <-
           Grant.refresh(
             endpoint,
             registration,
             token["refresh_token"],
             token["resource"],
             auth.req
           ) do
      {:ok, put(auth, {:token, auth.url}, refreshed(body, token))}
    else
      _ -> {:error, put(auth, {:token, auth.url}, Map.delete(token, "refresh_token"))}
    end
  end

  defp token(body, server, registration, requested) do
    %{
      "access_token" => body["access_token"],
      "refresh_token" => body["refresh_token"],
      "expires_at" => expires_at(body["expires_in"]),
      "scopes" => scope(body["scope"]) || requested,
      "requested_scopes" => requested,
      "issuer" => server.issuer,
      "token_endpoint" => server.metadata["token_endpoint"],
      "resource" => server.resource,
      "client_id" => registration["client_id"],
      "token_endpoint_auth_method" => registration["token_endpoint_auth_method"]
    }
  end

  # RFC 6749 §6: a refresh answer without a new refresh token leaves the
  # old one valid, and one without `scope` keeps the scopes as they were.
  defp refreshed(body, token) do
    %{
      token
      | "access_token" => body["access_token"],
        "refresh_token" => body["refresh_token"] || token["refresh_token"],
        "expires_at" => expires_at(body["expires_in"]),
        "scopes" => scope(body["scope"]) || token["scopes"]
    }
  end

  defp expires_at(seconds) when is_integer(seconds), do: System.system_time(:second) + seconds

  defp expires_at(seconds) when is_binary(seconds) do
    case Integer.parse(seconds) do
      {n, ""} -> expires_at(n)
      _ -> nil
    end
  end

  defp expires_at(_seconds), do: nil

  defp scope(scope) when is_binary(scope), do: String.split(scope)
  defp scope(_scope), do: nil

  # ---- state: in the session, and in the store when there is one

  @doc false
  @spec fetch(t(), Sake.Client.Auth.Store.key()) :: map() | nil
  def fetch(%__MODULE__{clients: clients} = auth, {:client, issuer} = key),
    do: clients[issuer] || stored(auth, key)

  def fetch(auth, key), do: stored(auth, key)

  defp stored(%__MODULE__{store: {module, arg}}, key) do
    case module.fetch(arg, key) do
      {:ok, value} when is_map(value) -> value
      _ -> nil
    end
  end

  defp stored(_auth, _key), do: nil

  @doc false
  @spec put(t(), Sake.Client.Auth.Store.key(), map()) :: t()
  def put(auth, {:client, issuer} = key, value) do
    persist(auth, key, value)
    %{auth | clients: Map.put(auth.clients, issuer, value)}
  end

  def put(auth, {:token, _url} = key, value) do
    persist(auth, key, value)
    %{auth | token: value}
  end

  defp persist(%__MODULE__{store: {module, arg}}, key, value),
    do: :ok = module.put(arg, key, value)

  defp persist(_auth, _key, _value), do: :ok
end
