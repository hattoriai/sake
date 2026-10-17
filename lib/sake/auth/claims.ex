defmodule Sake.Auth.Claims do
  @moduledoc false
  # The userinfo endpoint (OpenID Connect Core 1.0 §5.3): the claims of
  # the person an access token stands for, `sub` and what
  # `c:Sake.Auth.Subject.claims/2` returns for the token's scopes.
  #
  # The token is checked as at an MCP endpoint (`Sake.Auth.Bearer`: the
  # Bearer or the DPoP scheme, the proof, the person loaded, the scopes
  # narrowed to those they may hold now), with one difference: Sake's
  # access tokens are bound to a resource (RFC 8707), and the userinfo
  # endpoint takes a token whatever resource it is bound to, as long as
  # it holds `openid`. A client that signed a person in for an MCP
  # endpoint asks who they are with the token it has. A token without
  # `openid` gets `insufficient_scope` (403, §5.3.3).
  #
  # Core: the request as `Sake.Auth.Bearer` describes it, never the conn;
  # `Sake.Auth.UserInfo` reads it and renders the answer, or the
  # challenge as an OAuth error (RFC 6750 §3).

  alias Sake.Auth.{Bearer, Challenge, Config, Subject}

  @doc """
  The claims for the token of `request`, a `t:Sake.Auth.Bearer.request/0`,
  or the challenge that refuses it. `nonce` is the DPoP nonce to send
  back, when there is one.
  """
  @spec userinfo(Config.t(), Bearer.request()) ::
          {:ok, map(), String.t() | nil} | {:error, Challenge.t()}
  def userinfo(config, request) do
    url = Config.userinfo_url(config)

    with {:ok, accepted} <-
           Bearer.check(config, request, url, nil, any_resource: true, scope: ["openid"]),
         :ok <- openid(url, accepted) do
      claims =
        config.subject
        |> Subject.claims(accepted.principal, accepted.scopes)
        |> Map.put("sub", config.subject.id(accepted.principal))

      {:ok, claims, accepted.nonce}
    end
  end

  # A machine client's token stands for nobody, and never holds
  # `openid`: only a person's grant may ask for it.
  defp openid(url, accepted) do
    if "openid" in accepted.scopes and accepted.token.subject_id != nil,
      do: :ok,
      else: {:error, Bearer.insufficient_scope(url, ["openid"], accepted.dpop)}
  end
end
