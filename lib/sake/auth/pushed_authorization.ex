defmodule Sake.Auth.PushedAuthorization do
  @moduledoc false
  # The pushed authorization request endpoint's adapter (RFC 9126 §2): it
  # reads the parameters, the client's credentials and the DPoP proof,
  # hands them to `Sake.Auth.PAR`, and renders its answer as JSON, as the
  # token endpoint does: 201 with the request_uri. A DPoP nonce, when the
  # server requires them, goes on every answer once the proof is checked.
  # It is not there (404) without `par:`.
  @behaviour Plug
  import Plug.Conn

  alias Sake.Auth
  alias Sake.Auth.{ClientAuth, DPoP, PAR, Token}

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{method: "POST"} = conn, _opts) do
    config = Auth.config()

    if config.par == false do
      send_resp(conn, 404, "")
    else
      conn = Token.parse(conn)
      with_proof(conn, config, conn.body_params)
    end
  end

  def call(conn, _opts) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
    |> send_resp(405, "")
  end

  defp with_proof(conn, config, p) do
    case PAR.proof(config, get_req_header(conn, "dpop")) do
      {:ok, checked} ->
        conn
        |> DPoP.put_nonce(config)
        |> respond(PAR.request(config, p, ClientAuth.credentials(conn), checked))

      {:error, "use_dpop_nonce", description} ->
        conn |> DPoP.put_nonce(config) |> Token.error(400, "use_dpop_nonce", description)

      {:error, code, description} ->
        Token.error(conn, 400, code, description)
    end
  end

  defp respond(conn, {:ok, response}), do: Token.json(conn, 201, response)

  defp respond(conn, {:error, 401, code, description}) do
    conn
    |> put_resp_header("www-authenticate", ~s(Basic realm="sake"))
    |> Token.error(401, code, description)
  end

  defp respond(conn, {:error, status, code, description}),
    do: Token.error(conn, status, code, description)
end
