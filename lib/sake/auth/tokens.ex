defmodule Sake.Auth.Tokens do
  @moduledoc false
  alias Sake.Auth.{Config, TokenRecord}

  @spec generate() :: String.t()
  def generate, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  @spec hash(String.t()) :: String.t()
  def hash(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  @doc """
  Issues and stores an access/refresh pair. `attrs`: client_id,
  subject_id, scopes, resource, family_id, and optionally `jkt` (the DPoP
  key the access token is bound to), `refresh_jkt` (the one the
  refresh token is), and `acr` and `auth_time` (how and when the person
  signed in, RFC 9470).
  """
  @spec issue_pair(Config.t(), map()) ::
          {String.t(), String.t(), %{access: TokenRecord.t(), refresh: TokenRecord.t()}}
  def issue_pair(config, attrs) do
    {module, state} = Sake.Auth.store(config)
    {_access, _refresh, %{access: a, refresh: r}} = pair = new_pair(config, attrs)
    :ok = module.put_token(state, a)
    :ok = module.put_token(state, r)
    pair
  end

  @doc "An access/refresh pair as `issue_pair/2` makes it, not stored yet."
  @spec new_pair(Config.t(), map()) ::
          {String.t(), String.t(), %{access: TokenRecord.t(), refresh: TokenRecord.t()}}
  def new_pair(config, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    access = generate()
    refresh = generate()

    base = %TokenRecord{
      family_id: attrs.family_id,
      client_id: attrs.client_id,
      subject_id: attrs.subject_id,
      scopes: attrs.scopes,
      resource: attrs.resource,
      acr: attrs[:acr],
      auth_time: attrs[:auth_time],
      inserted_at: now
    }

    a = %{
      base
      | id: generate(),
        kind: :access,
        hash: hash(access),
        jkt: attrs[:jkt],
        expires_at: DateTime.add(now, config.access_token_ttl)
    }

    r = %{
      base
      | id: generate(),
        kind: :refresh,
        hash: hash(refresh),
        jkt: attrs[:refresh_jkt],
        expires_at: DateTime.add(now, config.refresh_token_ttl)
    }

    {access, refresh, %{access: a, refresh: r}}
  end

  @doc """
  Issues and stores an access token alone, for the grants that get no
  refresh token (client credentials, JWT bearer); it is a family of its
  own. `attrs`: client_id, subject_id (nil for a machine client), scopes,
  resource, and optionally `jkt`, `acr` and `auth_time`.
  """
  @spec issue_access(Config.t(), map()) :: {String.t(), TokenRecord.t()}
  def issue_access(config, attrs) do
    {module, state} = Sake.Auth.store(config)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    access = generate()

    record = %TokenRecord{
      id: generate(),
      kind: :access,
      hash: hash(access),
      family_id: generate(),
      client_id: attrs.client_id,
      subject_id: attrs.subject_id,
      scopes: attrs.scopes,
      resource: attrs.resource,
      jkt: attrs[:jkt],
      acr: attrs[:acr],
      auth_time: attrs[:auth_time],
      inserted_at: now,
      expires_at: DateTime.add(now, config.access_token_ttl)
    }

    :ok = module.put_token(state, record)
    {access, record}
  end

  @spec valid?(TokenRecord.t(), DateTime.t()) :: boolean()
  def valid?(%TokenRecord{revoked_at: nil, expires_at: exp}, now),
    do: DateTime.compare(exp, now) == :gt

  def valid?(_, _), do: false
end
