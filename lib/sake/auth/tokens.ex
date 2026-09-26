defmodule Sake.Auth.Tokens do
  @moduledoc false
  alias Sake.Auth.{Config, TokenRecord}

  @spec generate() :: String.t()
  def generate, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  @spec hash(String.t()) :: String.t()
  def hash(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  @doc "Issues and stores an access/refresh pair. `attrs`: client_id, subject_id, scopes, resource, family_id."
  @spec issue_pair(Config.t(), map()) ::
          {String.t(), String.t(), %{access: TokenRecord.t(), refresh: TokenRecord.t()}}
  def issue_pair(config, attrs) do
    {module, state} = Sake.Auth.store(config)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    access = generate()
    refresh = generate()

    base = %TokenRecord{
      family_id: attrs.family_id,
      client_id: attrs.client_id,
      subject_id: attrs.subject_id,
      scopes: attrs.scopes,
      resource: attrs.resource,
      inserted_at: now
    }

    a = %{
      base
      | id: generate(),
        kind: :access,
        hash: hash(access),
        expires_at: DateTime.add(now, config.access_token_ttl)
    }

    r = %{
      base
      | id: generate(),
        kind: :refresh,
        hash: hash(refresh),
        expires_at: DateTime.add(now, config.refresh_token_ttl)
    }

    :ok = module.put_token(state, a)
    :ok = module.put_token(state, r)
    {access, refresh, %{access: a, refresh: r}}
  end

  @spec valid?(TokenRecord.t(), DateTime.t()) :: boolean()
  def valid?(%TokenRecord{revoked_at: nil, expires_at: exp}, now),
    do: DateTime.compare(exp, now) == :gt

  def valid?(_, _), do: false
end
