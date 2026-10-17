defmodule Sake.Auth.AuthorizationRequest do
  @moduledoc false
  # An authorization request, validated: the client, where the code goes,
  # the PKCE challenge, the scopes and the resource (RFC 8707) it is for.
  #
  # `validate/3` takes the request's parameters as a map of strings,
  # wherever they came from: the authorize endpoint's query string today,
  # a pushed authorization request or a device authorization request
  # later. Parameters a later endpoint adds (`dpop_jkt`, `max_age`,
  # `acr_values`) go in `extra`, so the struct and `validate/3` keep their
  # shape. Its keys are strings and its values JSON, so that a pushed
  # request (RFC 9126) can be stored with it. It holds `"dpop_jkt"`
  # (RFC 9449 §10) when the code is to be bound to a DPoP key: from the
  # parameter of that name, or from the proof of a pushed request. It
  # holds `"acr_values"` (a list) and `"max_age"` (seconds) when the
  # client asks how the person must have signed in (RFC 9470), on every
  # path: the authorize endpoint, a pushed request, a device request. It
  # holds `"nonce"` with `openid:`, when the client sends OpenID
  # Connect's `nonce` (on the code flow alone), for the ID token.
  #
  # With `openid:`, the scopes may include the authorization server's
  # own `openid`, `profile` and `email`, which no server declares (a
  # request without `scope` gets the servers' scopes, without those). A
  # request for `openid` may name the userinfo endpoint as its
  # `resource`, and one that names no resource where none can be chosen
  # for it gets a token for the userinfo endpoint: a client that only
  # signs people in needs no MCP endpoint.
  #
  # A device authorization request (RFC 8628) has no redirect URI, state
  # or PKCE challenge: those three are nil on that path alone, and
  # `flow/1` tells the two apart by its missing redirect URI.
  #
  # Core: it takes the configuration and plain data, and never sees the
  # conn.

  alias Sake.Auth.{Authentication, Client, Clients, Config, Redirect, Resource}

  @device_code "urn:ietf:params:oauth:grant-type:device_code"

  @type t :: %__MODULE__{
          client_id: String.t(),
          redirect_uri: String.t() | nil,
          state: String.t() | nil,
          code_challenge: String.t() | nil,
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

  With `:device`, the parameters of a device authorization request (RFC
  8628 §3.1) from an authenticated `client`: only the scopes, the
  resource, `acr_values` and `max_age`, and the client must be allowed
  the device grant. Its error
  goes in the endpoint's JSON answer.
  """
  @spec validate(Config.t(), Client.t(), map(), :authorization_code | :device) ::
          {:ok, t()} | {:error, String.t(), String.t()}
  def validate(config, client, p, flow \\ :authorization_code) do
    known = config |> Config.request_scopes() |> Enum.map(&elem(&1, 0))
    requested = requested_scopes(p, config |> Config.scopes() |> Enum.map(&elem(&1, 0)))

    with :ok <- check_flow(flow, p, client),
         :ok <- check_scopes(requested, known, client),
         {:ok, extra} <- extra(config, flow, p),
         {:ok, resource} <- requested_resource(config, p["resource"], requested) do
      {:ok, %{request(flow, client, p, requested, resource) | extra: extra}}
    else
      :error ->
        {:error, "invalid_target", "The resource is not served by this authorization server"}

      error ->
        error
    end
  end

  @doc "Which flow a validated request belongs to: only a device request has no redirect URI."
  @spec flow(t()) :: :authorization_code | :device
  def flow(%__MODULE__{redirect_uri: nil}), do: :device
  def flow(%__MODULE__{}), do: :authorization_code

  defp check_flow(:authorization_code, p, client) do
    with :ok <- check_response_type(p),
         :ok <- check_challenge(p),
         do: check_grant_type(client, "authorization_code", "authorization code")
  end

  defp check_flow(:device, _p, client),
    do: check_grant_type(client, @device_code, "device authorization")

  defp request(:authorization_code, client, p, scopes, resource) do
    %__MODULE__{
      client_id: client.id,
      redirect_uri: p["redirect_uri"],
      code_challenge: p["code_challenge"],
      state: p["state"],
      scopes: scopes,
      resource: resource
    }
  end

  defp request(:device, client, _p, scopes, resource),
    do: %__MODULE__{client_id: client.id, scopes: scopes, resource: resource}

  # The parameters of the features that came after the request's shape:
  # the DPoP key the code is bound to, and what the sign-in must be
  # (RFC 9470).
  defp extra(config, flow, p) do
    with {:ok, dpop} <- dpop_jkt(config, flow, p),
         {:ok, nonce} <- nonce(config, flow, p),
         {:ok, authentication} <- Authentication.params(p, config.acr_values),
         do: {:ok, dpop |> Map.merge(nonce) |> Map.merge(authentication)}
  end

  # OpenID Connect Core §3.1.2.1: the `nonce` the ID token carries back,
  # for the client to tie it to its request. A server without `openid:`
  # ignores it; a device request has no ID token to put it in before
  # the person approves, and takes none (no browser carries it).
  @max_nonce 512

  defp nonce(%Config{openid: false}, _flow, _p), do: {:ok, %{}}
  defp nonce(_config, :device, _p), do: {:ok, %{}}

  defp nonce(_config, :authorization_code, p) do
    case p["nonce"] do
      nil ->
        {:ok, %{}}

      nonce when is_binary(nonce) and nonce != "" and byte_size(nonce) <= @max_nonce ->
        {:ok, %{"nonce" => nonce}}

      _ ->
        {:error, "invalid_request", "nonce must be a string of at most #{@max_nonce} bytes"}
    end
  end

  # RFC 9449 §10: `dpop_jkt` binds the code to a DPoP key, by its RFC
  # 7638 thumbprint (a base64url SHA-256 hash, 43 characters). A server
  # without DPoP ignores it, as it ignores any parameter it does not know.
  defp dpop_jkt(%Config{dpop: false}, _flow, _p), do: {:ok, %{}}
  defp dpop_jkt(_config, :device, _p), do: {:ok, %{}}

  defp dpop_jkt(_config, :authorization_code, p) do
    case p["dpop_jkt"] do
      nil -> {:ok, %{}}
      jkt -> if thumbprint?(jkt), do: {:ok, %{"dpop_jkt" => jkt}}, else: bad_jkt()
    end
  end

  defp bad_jkt, do: {:error, "invalid_request", "dpop_jkt must be a JWK SHA-256 thumbprint"}

  @doc "Whether `value` reads as an RFC 7638 SHA-256 thumbprint."
  @spec thumbprint?(term()) :: boolean()
  def thumbprint?(value),
    do:
      is_binary(value) and byte_size(value) == 43 and
        match?({:ok, <<_::binary-size(32)>>}, Base.url_decode64(value, padding: false))

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

  defp check_grant_type(client, grant_type, name) do
    if grant_type in client.grant_types,
      do: :ok,
      else: {:error, "unauthorized_client", "The client may not use the #{name} grant"}
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

  # With `openid:`, a request for `openid` may be for the userinfo
  # endpoint: named, or when no other resource can be chosen.
  defp requested_resource(%Config{openid: false} = config, value, _scopes),
    do: resource(config, value)

  defp requested_resource(config, value, scopes) do
    userinfo = Config.userinfo_url(config)

    cond do
      "openid" not in scopes -> resource(config, value)
      value == userinfo -> {:ok, userinfo}
      value == nil -> with :error <- resource(config, nil), do: {:ok, userinfo}
      true -> resource(config, value)
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
        if String.contains?(pattern, ":"),
          do: :error,
          else: {:ok, Resource.issuer_origin(config) <> pattern}

      _ ->
        :error
    end
  end

  def resource(config, value) when is_binary(value) do
    uri = URI.parse(value)
    path = String.trim_trailing(uri.path || "", "/")
    origin = Resource.issuer_origin(config)

    cond do
      not same_origin?(uri, URI.parse(config.issuer)) -> :error
      config.resources == nil -> {:ok, origin <> path}
      Enum.any?(config.resources, &Resource.path_match?(&1, path)) -> {:ok, origin <> path}
      true -> :error
    end
  end

  def resource(_config, _), do: :error

  defp same_origin?(uri, issuer) do
    uri.scheme == issuer.scheme and uri.host == issuer.host and uri.port == issuer.port and
      uri.fragment == nil and uri.query == nil
  end
end
