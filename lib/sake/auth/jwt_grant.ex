defmodule Sake.Auth.JWTGrant do
  @moduledoc false
  # The JWT bearer grant (RFC 7523 §2.1) at the token endpoint: a JWT from
  # a trusted issuer, verified with that issuer's keys, standing for the
  # account the subject module maps its claims to.
  #
  # For an enterprise identity provider (the `:id_jag` profile) the JWT is
  # an Identity Assertion JWT Authorization Grant
  # (draft-ietf-oauth-identity-assertion-authz-grant): typed
  # `oauth-id-jag+jwt`, issued for this authorization server, to the very
  # client presenting it (`client_id`), for an MCP server of this
  # authorization server (`resource`, when present), and usable once
  # (`jti`). A workload identity token (the `:workload` profile) carries
  # none of that: it must be for this authorization server, unexpired,
  # and is single use when it has a `jti`. Either may be valid for no
  # longer than the issuer's `max_lifetime` from now.

  alias Sake.Auth.{AuthorizationRequest, Config, JWKS, JWT, Replay, Subject, TrustedIssuer}

  @type grant :: %{principal: term(), claims: map(), issuer: TrustedIssuer.t()}

  @spec verify(Config.t(), Sake.Auth.Client.t(), String.t()) ::
          {:ok, grant()} | {:error, String.t(), String.t()}
  def verify(config, client, assertion) do
    with {:ok, issuer} <- trusted(config, assertion),
         :ok <- may_present(issuer, client),
         {:ok, claims} <- verified(config, issuer, assertion),
         :ok <- short_lived(issuer, claims),
         :ok <- bound(issuer, claims, client),
         :ok <- once(issuer, claims),
         {:ok, principal} <- principal(config, claims, issuer) do
      {:ok, %{principal: principal, claims: claims, issuer: issuer}}
    end
  end

  @doc "The limits on the scopes a grant may get: the client's, the issuer's, and an ID-JAG's own."
  @spec scope_limits(Sake.Auth.Client.t(), grant()) :: [[String.t()] | nil]
  def scope_limits(client, %{issuer: issuer, claims: claims}) do
    claimed =
      case {issuer.profile, claims["scope"]} do
        {:id_jag, scope} when is_binary(scope) -> String.split(scope)
        _ -> nil
      end

    [client.scopes, issuer.scopes, claimed]
  end

  @doc """
  The resource the token is for: the `resource` parameter, or the one an
  ID-JAG names; when the ID-JAG names any, the parameter must be one of
  them.
  """
  @spec resource(Config.t(), grant(), term()) ::
          {:ok, String.t()} | {:error, String.t(), String.t()}
  def resource(config, %{claims: claims, issuer: issuer}, requested) do
    claimed = if issuer.profile == :id_jag, do: strings(claims["resource"]), else: []

    chosen =
      case {requested, claimed} do
        {nil, [one]} -> one
        _ -> requested
      end

    if claimed != [] and chosen not in claimed,
      do: {:error, "invalid_target", "The grant was not issued for this resource"},
      else: served(config, chosen)
  end

  defp served(config, resource) do
    case AuthorizationRequest.resource(config, resource) do
      {:ok, resource} ->
        {:ok, resource}

      :error ->
        {:error, "invalid_target", "The resource is not served by this authorization server"}
    end
  end

  defp strings(value) when is_binary(value), do: [value]
  defp strings(values) when is_list(values), do: Enum.filter(values, &is_binary/1)
  defp strings(_value), do: []

  # ---- the checks

  defp trusted(config, assertion) do
    with {:ok, _header, %{"iss" => iss}} when is_binary(iss) <- JWT.peek(assertion),
         %TrustedIssuer{} = issuer <- Enum.find(config.trusted_issuers, &(&1.issuer == iss)) do
      {:ok, issuer}
    else
      _ -> {:error, "invalid_grant", "The grant is not from a trusted issuer"}
    end
  end

  defp may_present(%TrustedIssuer{clients: :any}, _client), do: :ok

  defp may_present(%TrustedIssuer{clients: clients}, client) do
    if client.id in clients,
      do: :ok,
      else: {:error, "unauthorized_client", "The client may not present this issuer's grants"}
  end

  defp verified(config, issuer, assertion) do
    case JWKS.verify(config, assertion, JWKS.source(issuer), options(config, issuer)) do
      {:ok, claims} -> {:ok, claims}
      {:error, reason} -> {:error, "invalid_grant", "The grant is invalid: #{describe(reason)}"}
    end
  end

  defp options(config, issuer) do
    [
      iss: issuer.issuer,
      aud: issuer.audiences || [config.issuer, Config.token_url(config)]
    ] ++
      case issuer.profile do
        :id_jag ->
          [typ: "oauth-id-jag+jwt", required: ~w(iss sub aud client_id jti exp iat)]

        :workload ->
          [required: ~w(iss sub aud exp)]
      end
  end

  defp describe({:missing_claim, name}), do: "no #{name} claim"
  defp describe(:no_key), do: "no key of the issuer verifies it"
  defp describe(:unreachable), do: "the issuer's keys could not be fetched"
  defp describe(reason), do: reason |> to_string() |> String.replace("_", " ")

  # The clock leeway allows for an issuer whose clock is a little ahead.
  defp short_lived(issuer, %{"exp" => exp}) do
    if exp <= System.system_time(:second) + issuer.max_lifetime + JWT.leeway(),
      do: :ok,
      else: {:error, "invalid_grant", "The grant is valid for too long"}
  end

  defp bound(%TrustedIssuer{profile: :id_jag}, %{"client_id" => id}, client) do
    if id == client.id,
      do: :ok,
      else: {:error, "invalid_grant", "The grant was issued to another client"}
  end

  defp bound(_issuer, _claims, _client), do: :ok

  defp once(issuer, %{"jti" => jti, "exp" => exp}) when is_binary(jti) do
    case Replay.once(issuer.issuer, jti, exp) do
      :ok -> :ok
      {:error, :replayed} -> {:error, "invalid_grant", "The grant was already used"}
    end
  end

  defp once(_issuer, %{"jti" => _}),
    do: {:error, "invalid_grant", "The grant is invalid: malformed"}

  defp once(_issuer, _claims), do: :ok

  defp principal(config, claims, issuer) do
    case Subject.assertion_principal(config.subject, claims, issuer) do
      {:ok, principal} -> {:ok, principal}
      :error -> {:error, "invalid_grant", "The grant's subject has no account here"}
    end
  end
end
