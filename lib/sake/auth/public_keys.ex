defmodule Sake.Auth.PublicKeys do
  @moduledoc false
  # The JWKS endpoint's adapter, `GET {oauth_path}/jwks`: the public
  # signing keys (`Sake.Auth.SigningKeys.jwks/1`), the `jwks_uri` of the
  # metadata, which clients verify ID tokens with. Without `openid:`
  # there is no such endpoint.
  @behaviour Plug
  import Plug.Conn

  alias Sake.Auth
  alias Sake.Auth.SigningKeys

  # A client caches the set; a short max-age lets it see a rotated key
  # soon, and a client that meets an unknown `kid` refetches it anyway.
  @max_age 300

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{method: "GET"} = conn, _opts) do
    case Auth.configured() do
      %{openid: openid} = config when openid != false ->
        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("cache-control", "public, max-age=#{@max_age}")
        |> send_resp(200, JSON.encode!(SigningKeys.jwks(config)))

      _ ->
        send_resp(conn, 404, "")
    end
  end

  def call(conn, _opts), do: send_resp(conn, 405, "")
end
