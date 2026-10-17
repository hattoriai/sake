defmodule Sake.Auth.Revoke do
  @moduledoc false
  # The revocation endpoint's adapter (RFC 7009): it reads the parameters
  # and the client's credentials, hands them to `Sake.Auth.Revocation`,
  # and renders its answer.
  @behaviour Plug
  import Plug.Conn

  alias Sake.Auth
  alias Sake.Auth.{ClientAuth, Revocation, Token}

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{method: "POST"} = conn, _opts) do
    config = Auth.config()
    conn = Token.parse(conn)

    case Revocation.revoke(config, conn.body_params, ClientAuth.credentials(conn)) do
      :ok ->
        conn |> put_resp_header("cache-control", "no-store") |> send_resp(200, "")

      {:error, 401, code, description} ->
        conn
        |> put_resp_header("www-authenticate", ~s(Basic realm="sake"))
        |> Token.error(401, code, description)
    end
  end

  def call(conn, _opts) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
    |> send_resp(405, "")
  end
end
