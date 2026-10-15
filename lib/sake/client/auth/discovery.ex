defmodule Sake.Client.Auth.Discovery do
  @moduledoc false
  # From a 401 to an authorization server: the protected resource metadata
  # (RFC 9728) names the server and the resource, and the server's own
  # metadata (RFC 8414 or OpenID Connect Discovery) its endpoints.
  #
  # The result is a map: `resource` (the identifier to send as RFC 8707's
  # `resource` parameter), `scopes_supported` (from the resource metadata,
  # or nil), `issuer` (the validated issuer, recorded for RFC 9207's `iss`
  # check) and `metadata` (the authorization server's document).

  alias Sake.Client.Auth.HTTP
  alias Sake.Client.Challenge

  @resource_well_known "/.well-known/oauth-protected-resource"
  @oauth_well_known "/.well-known/oauth-authorization-server"
  @openid_well_known "/.well-known/openid-configuration"

  @type server :: %{
          resource: String.t(),
          scopes_supported: [String.t()] | nil,
          issuer: String.t(),
          metadata: map()
        }

  @doc """
  Discovers the authorization server for `url`. `preferred` is an issuer
  to pick when the resource lists several (the one pre-registered
  credentials belong to). `interactive` is false for a grant that never
  sends anyone to the authorization endpoint (client credentials, a JWT
  grant): only the token endpoint is required then.
  """
  @spec discover(String.t(), Challenge.t() | nil, String.t() | nil, keyword(), boolean()) ::
          {:ok, server()} | {:error, term()}
  def discover(url, challenge, preferred, req, interactive \\ true) do
    case protected_resource(url, challenge, req) do
      {:ok, resource} ->
        issuer = choose(resource["authorization_servers"], preferred)

        with {:ok, metadata} <- authorization_server(issuer, req),
             :ok <- check(metadata, interactive) do
          {:ok,
           %{
             resource: resource["resource"],
             scopes_supported: scopes(resource["scopes_supported"]),
             issuer: issuer,
             metadata: metadata
           }}
        end

      :none ->
        legacy(url, req, interactive)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---- protected resource metadata

  # The URL in the challenge when there is one; otherwise the well-known
  # URI with the endpoint's path inserted, then the one at the root. Only
  # when neither exists does the server count as a 2025-03-26 one, which
  # had no resource metadata at all.
  defp protected_resource(url, %Challenge{resource_metadata: from_header}, req)
       when is_binary(from_header) do
    case fetch_resource(from_header, url, req) do
      :not_found -> {:error, {:no_resource_metadata, from_header}}
      result -> result
    end
  end

  defp protected_resource(url, _challenge, req) do
    url
    |> resource_metadata_urls()
    |> Enum.reduce_while(:none, fn candidate, :none ->
      case fetch_resource(candidate, url, req) do
        :not_found -> {:cont, :none}
        result -> {:halt, result}
      end
    end)
  end

  defp fetch_resource(candidate, url, req) do
    case HTTP.get_json(candidate, req) do
      {:ok, doc} -> validate_resource(doc, url)
      {:error, {:insecure_url, _} = reason} -> {:error, reason}
      {:error, _} -> :not_found
    end
  end

  # RFC 9728 §3.3 and §7.3: the document must be about the resource the
  # client is talking to. Its identifier may be the endpoint itself or a
  # path prefix of it on the same origin (a root document describes the
  # whole origin); anything else, a server elsewhere above all, is
  # refused before the client asks anyone for a token.
  defp validate_resource(
         %{"resource" => resource, "authorization_servers" => [_ | _] = servers} = doc,
         url
       )
       when is_binary(resource) do
    cond do
      not Enum.all?(servers, &is_binary/1) -> {:error, :invalid_resource_metadata}
      not resource_matches?(resource, url) -> {:error, {:resource_mismatch, resource}}
      true -> {:ok, doc}
    end
  end

  defp validate_resource(_doc, _url), do: {:error, :invalid_resource_metadata}

  @doc "The well-known resource metadata URLs for an endpoint URL, in the order to try them."
  @spec resource_metadata_urls(String.t()) :: [String.t()]
  def resource_metadata_urls(url) do
    uri = URI.parse(url)

    case trimmed_path(uri) do
      "" -> [origin(uri) <> @resource_well_known]
      path -> [origin(uri) <> @resource_well_known <> path, origin(uri) <> @resource_well_known]
    end
  end

  @doc "Whether a resource identifier names `url` itself or a path prefix of it, on the same origin."
  @spec resource_matches?(String.t(), String.t()) :: boolean()
  def resource_matches?(resource, url) do
    r = URI.parse(resource)
    u = URI.parse(url)

    r.fragment == nil and same_origin?(r, u) and
      List.starts_with?(segments(u), segments(r))
  end

  defp same_origin?(a, b) do
    is_binary(a.scheme) and is_binary(a.host) and
      String.downcase(a.scheme) == String.downcase(b.scheme || "") and
      String.downcase(a.host) == String.downcase(b.host || "") and a.port == b.port
  end

  defp segments(uri), do: String.split(uri.path || "", "/", trim: true)

  defp choose(servers, preferred), do: Enum.find(servers, hd(servers), &(&1 == preferred))

  defp scopes([_ | _] = scopes), do: if(Enum.all?(scopes, &is_binary/1), do: scopes)
  defp scopes(_scopes), do: nil

  # ---- authorization server metadata

  @doc """
  The metadata URLs for an issuer, in the order the specification gives:
  RFC 8414 then OpenID Connect with the issuer's path inserted after the
  well-known prefix, then OpenID Connect with it appended.
  """
  @spec metadata_urls(String.t()) :: [String.t()]
  def metadata_urls(issuer) do
    uri = URI.parse(issuer)
    origin = origin(uri)

    case trimmed_path(uri) do
      "" ->
        [origin <> @oauth_well_known, origin <> @openid_well_known]

      path ->
        [
          origin <> @oauth_well_known <> path,
          origin <> @openid_well_known <> path,
          origin <> path <> @openid_well_known
        ]
    end
  end

  @doc "The metadata of an authorization server (an enterprise identity provider, say) by its issuer."
  @spec issuer_metadata(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def issuer_metadata(issuer, req), do: authorization_server(issuer, req)

  # RFC 8414 §3.3: a document whose `issuer` is not, character for
  # character, the issuer the client built the URL from is not used — it
  # could be an attacker's document naming an honest server, or the other
  # way round. That ends discovery rather than trying the next URL.
  defp authorization_server(issuer, req) do
    issuer
    |> metadata_urls()
    |> Enum.reduce_while({:error, {:no_authorization_server_metadata, issuer}}, fn url, acc ->
      case HTTP.get_json(url, req) do
        {:ok, %{"issuer" => ^issuer} = doc} -> {:halt, {:ok, doc}}
        {:ok, %{"issuer" => other}} -> {:halt, {:error, {:issuer_mismatch, issuer, other}}}
        {:error, {:insecure_url, _} = reason} -> {:halt, {:error, reason}}
        _ -> {:cont, acc}
      end
    end)
  end

  # The client must see S256 among the PKCE methods before it sends anyone
  # to the authorization endpoint; an absent list means no PKCE at all. The
  # endpoint itself must be HTTPS like every other one: the person's
  # browser, not this client, makes that request.
  defp check(metadata, false) do
    if HTTP.secure?(metadata["token_endpoint"]),
      do: :ok,
      else: {:error, :invalid_authorization_server_metadata}
  end

  defp check(metadata, true) do
    endpoint = metadata["authorization_endpoint"]

    cond do
      not is_binary(endpoint) or not is_binary(metadata["token_endpoint"]) ->
        {:error, :invalid_authorization_server_metadata}

      not HTTP.secure?(endpoint) ->
        {:error, {:insecure_url, endpoint}}

      "S256" not in List.wrap(metadata["code_challenge_methods_supported"]) ->
        {:error, :pkce_not_supported}

      true ->
        :ok
    end
  end

  # ---- 2025-03-26

  # A server without resource metadata is its own authorization server, as
  # in the 2025-03-26 revision: its metadata document sits at the root of
  # its origin, and without one the default `/authorize`, `/token` and
  # `/register` paths apply. That revision had no notion of an issuer
  # distinct from the server, so a document from the server's origin is
  # accepted when its issuer is on that same origin; PKCE was already
  # mandatory then, so the default endpoints are taken to support S256.
  defp legacy(url, req, interactive) do
    origin = url |> URI.parse() |> origin()

    with {:ok, metadata} <- legacy_metadata(origin, req),
         :ok <- check(metadata, interactive) do
      {:ok,
       %{
         resource: canonical(url),
         scopes_supported: nil,
         issuer: metadata["issuer"],
         metadata: metadata
       }}
    end
  end

  defp legacy_metadata(origin, req) do
    case HTTP.get_json(origin <> @oauth_well_known, req) do
      {:ok, %{"issuer" => issuer} = doc} when is_binary(issuer) ->
        if same_origin?(URI.parse(issuer), URI.parse(origin)),
          do: {:ok, doc},
          else: {:error, {:issuer_mismatch, origin, issuer}}

      {:error, {:insecure_url, _} = reason} ->
        {:error, reason}

      _ ->
        {:ok,
         %{
           "issuer" => origin,
           "authorization_endpoint" => origin <> "/authorize",
           "token_endpoint" => origin <> "/token",
           "registration_endpoint" => origin <> "/register",
           "code_challenge_methods_supported" => ["S256"]
         }}
    end
  end

  @doc """
  The canonical URI of an endpoint (RFC 8707 §2): lowercase scheme and
  host, no fragment, no trailing slash.
  """
  @spec canonical(String.t()) :: String.t()
  def canonical(url) do
    uri = URI.parse(url)
    query = if uri.query, do: "?" <> uri.query, else: ""
    origin(uri) <> trimmed_path(uri) <> query
  end

  # ---- URLs

  defp origin(%URI{scheme: scheme, host: host, port: port}) do
    scheme = String.downcase(scheme || "")
    host = String.downcase(host || "")
    host = if String.contains?(host, ":"), do: "[" <> host <> "]", else: host
    default = URI.default_port(scheme)
    if port in [nil, default], do: "#{scheme}://#{host}", else: "#{scheme}://#{host}:#{port}"
  end

  defp trimmed_path(uri), do: String.trim_trailing(uri.path || "", "/")
end
