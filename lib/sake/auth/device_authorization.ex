defmodule Sake.Auth.DeviceAuthorization do
  @moduledoc false
  # The device authorization endpoint's adapter (RFC 8628 §3.1): it reads
  # the parameters and the client's credentials, hands them to
  # `Sake.Auth.Device`, and renders its answer as JSON, as the token
  # endpoint does. It is not there (404) without `device:`.
  @behaviour Plug
  import Plug.Conn

  alias Sake.Auth
  alias Sake.Auth.{ClientAuth, Device, Token}

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{method: "POST"} = conn, _opts) do
    config = Auth.config()

    if config.device == false do
      send_resp(conn, 404, "")
    else
      conn = Token.parse(conn)
      respond(conn, Device.authorize(config, conn.body_params, ClientAuth.credentials(conn)))
    end
  end

  def call(conn, _opts) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
    |> send_resp(405, "")
  end

  defp respond(conn, {:ok, response}), do: Token.json(conn, 200, response)

  defp respond(conn, {:error, 401, code, description}) do
    conn
    |> put_resp_header("www-authenticate", ~s(Basic realm="sake"))
    |> Token.error(401, code, description)
  end

  defp respond(conn, {:error, status, code, description}),
    do: Token.error(conn, status, code, description)
end
