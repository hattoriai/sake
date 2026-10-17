defmodule Sake.Auth.UserInfo do
  @moduledoc false
  # The userinfo endpoint's adapter (OpenID Connect Core 1.0 §5.3), `GET`
  # or `POST {oauth_path}/userinfo` with the access token in the
  # `Authorization` header: it reads the request as `Sake.Auth.Bearer`
  # describes it, hands it to `Sake.Auth.Claims`, and renders the claims
  # as JSON, or the refusal as an OAuth error (RFC 6750 §3): the
  # challenges in `WWW-Authenticate`, and a JSON body with the `error`
  # and its `error_description`. Without `openid:` there is no such
  # endpoint.
  @behaviour Plug
  import Plug.Conn

  alias Sake.Auth
  alias Sake.Auth.{Challenge, Claims, Resource, Token}

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{method: method} = conn, _opts) when method in ["GET", "POST"] do
    case Auth.configured() do
      %{openid: openid} = config when openid != false -> userinfo(conn, config)
      _ -> send_resp(conn, 404, "")
    end
  end

  def call(conn, _opts), do: send_resp(conn, 405, "")

  defp userinfo(conn, config) do
    request = %{
      authorization: get_req_header(conn, "authorization"),
      dpop: get_req_header(conn, "dpop"),
      method: conn.method,
      url: Resource.url(conn)
    }

    case Claims.userinfo(config, request) do
      {:ok, claims, nonce} -> conn |> put_nonce(nonce) |> Token.json(200, claims)
      {:error, challenge} -> refuse(conn, challenge)
    end
  end

  # RFC 6750 §3.1: a request with no token at all gets no error code in
  # its challenge; its body still says what is wrong.
  defp refuse(conn, %Challenge{} = challenge) do
    conn
    |> put_nonce(challenge.nonce)
    |> prepend_resp_headers(for(c <- challenge.www_authenticate, do: {"www-authenticate", c}))
    |> Token.error(
      challenge.status,
      challenge.error || "invalid_token",
      challenge.error_description || description(challenge.status)
    )
  end

  defp description(403), do: "The access token does not hold the openid scope"
  defp description(_status), do: "A valid access token is required"

  defp put_nonce(conn, nil), do: conn
  defp put_nonce(conn, nonce), do: put_resp_header(conn, "dpop-nonce", nonce)
end
