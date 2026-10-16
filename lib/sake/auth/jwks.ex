defmodule Sake.Auth.JWKS do
  @moduledoc false
  # The public keys a JWT is verified with: a client's (`private_key_jwt`),
  # a trusted issuer's, or an external authorization server's (its JWT
  # access tokens, see `Sake.Auth.External`). Keys given inline are used
  # as they are. Keys at a `jwks_uri` are fetched with the guards of a
  # Client ID Metadata Document (HTTPS unless `allow_insecure`, no
  # redirects, 64 KB, five seconds) and cached for their `max-age`. An
  # issuer with neither has its `jwks_uri` read from its metadata.
  #
  # A token signed with a key the cached set does not have (a `kid` it
  # does not list) refetches the set once, so a key the issuer rotated in
  # is picked up; at most once a minute per URL, so nobody can make the
  # server fetch on every request by inventing key IDs.

  alias Sake.Auth.{CIMD, Client, Config, External, JWT, TrustedIssuer}

  @refetch_after 60

  @type source :: {:jwks, map()} | {:uri, String.t()} | {:issuer, String.t()}

  @doc "Where a client's or a trusted issuer's keys are."
  @spec source(Client.t() | TrustedIssuer.t()) :: source() | nil
  def source(%{jwks: %{} = jwks}), do: {:jwks, jwks}
  def source(%{jwks_uri: uri}) when is_binary(uri), do: {:uri, uri}
  def source(%TrustedIssuer{issuer: issuer}), do: {:issuer, issuer}
  def source(_client), do: nil

  @doc "Verifies `token` with the keys at `source` (see `Sake.Auth.JWT.verify/3`)."
  @spec verify(Config.t() | External.t(), String.t(), source() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def verify(_config, _token, nil, _opts), do: {:error, :no_key}

  def verify(config, token, source, opts) do
    with {:ok, keys, fetched_at} <- keys(config, source, false),
         do: retried(JWT.verify(token, keys, opts), fetched_at, config, token, source, opts)
  end

  defp retried({:error, :no_key}, fetched_at, config, token, source, opts)
       when is_integer(fetched_at) do
    if stale?(fetched_at), do: refetched(config, token, source, opts), else: {:error, :no_key}
  end

  defp retried(result, _fetched_at, _config, _token, _source, _opts), do: result

  defp stale?(fetched_at), do: now() - fetched_at >= @refetch_after

  defp refetched(config, token, source, opts) do
    with {:ok, keys, _fetched_at} <- keys(config, source, true),
         do: JWT.verify(token, keys, opts)
  end

  # ---- key sets

  defp keys(_config, {:jwks, jwks}, _refetch), do: {:ok, jwks, nil}

  defp keys(config, {:uri, uri}, refetch) do
    case cached({:jwks, uri}, refetch) do
      {:ok, {keys, fetched_at}} -> {:ok, keys, fetched_at}
      :error -> fetch_keys(config, uri)
    end
  end

  defp keys(config, {:issuer, issuer}, refetch) do
    with {:ok, uri} <- jwks_uri(config, issuer), do: keys(config, {:uri, uri}, refetch)
  end

  defp cached(_key, true), do: :error
  defp cached(key, false), do: CIMD.Cache.get(key)

  defp fetch_keys(config, uri) do
    with {:ok, body, ttl} <- download(config, uri),
         {:ok, %{"keys" => keys}} when is_list(keys) <- JSON.decode(body) do
      fetched_at = now()
      CIMD.Cache.put({:jwks, uri}, {keys, fetched_at}, ttl)
      {:ok, keys, fetched_at}
    else
      {:error, :unreachable} -> {:error, :unreachable}
      _ -> {:error, :invalid_jwks}
    end
  end

  # ---- an issuer's metadata

  # The OpenID Connect location (the well-known path appended to the
  # issuer), then RFC 8414's (inserted before its path). The document must
  # name the issuer exactly, as a client checks it (RFC 8414 §3.3).
  defp jwks_uri(config, issuer) do
    case CIMD.Cache.get({:jwks_uri, issuer}) do
      {:ok, uri} ->
        {:ok, uri}

      :error ->
        issuer
        |> metadata_urls()
        |> Enum.find_value({:error, :unreachable}, &metadata_jwks_uri(config, issuer, &1))
    end
  end

  defp metadata_jwks_uri(config, issuer, url) do
    with {:ok, body, ttl} <- download(config, url),
         {:ok, %{"issuer" => ^issuer, "jwks_uri" => uri}} when is_binary(uri) <- JSON.decode(body) do
      CIMD.Cache.put({:jwks_uri, issuer}, uri, ttl)
      {:ok, uri}
    else
      _ -> nil
    end
  end

  defp metadata_urls(issuer) do
    uri = URI.parse(issuer)
    path = String.trim_trailing(uri.path || "", "/")
    origin = URI.to_string(%{uri | path: nil, query: nil, fragment: nil})

    [
      origin <> path <> "/.well-known/openid-configuration",
      origin <> "/.well-known/oauth-authorization-server" <> path
    ]
  end

  defp download(config, url) do
    uri = URI.parse(url)

    if uri.scheme == "https" or (config.allow_insecure and uri.scheme == "http"),
      do: CIMD.download(uri),
      else: {:error, :unreachable}
  end

  defp now, do: System.system_time(:second)
end
