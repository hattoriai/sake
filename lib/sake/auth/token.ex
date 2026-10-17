defmodule Sake.Auth.Token do
  @moduledoc false
  # The token endpoint's adapter: it reads the parameters, the client's
  # credentials and the DPoP proof from the request, hands them to
  # `Sake.Auth.TokenGrants`, and renders its answer as JSON. A DPoP
  # nonce, when the server requires them, goes on every answer once the
  # proof is checked.
  @behaviour Plug
  import Plug.Conn

  alias Sake.Auth
  alias Sake.Auth.{ClientAuth, DPoP, TokenGrants}

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{method: "POST"} = conn, _opts) do
    config = Auth.config()
    conn = parse(conn)
    p = conn.body_params

    case TokenGrants.supported(config, p) do
      :ok -> with_proof(conn, config, p)
      {:error, status, code, description} -> error(conn, status, code, description)
    end
  end

  def call(conn, _opts) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
    |> send_resp(405, "")
  end

  defp with_proof(conn, config, p) do
    case TokenGrants.proof(config, get_req_header(conn, "dpop")) do
      {:ok, checked} ->
        conn
        |> DPoP.put_nonce(config)
        |> respond(TokenGrants.exchange(config, p, ClientAuth.credentials(conn), checked))

      {:error, "use_dpop_nonce", description} ->
        conn |> DPoP.put_nonce(config) |> error(400, "use_dpop_nonce", description)

      {:error, code, description} ->
        error(conn, 400, code, description)
    end
  end

  defp respond(conn, {:ok, response}), do: json(conn, 200, response)

  defp respond(conn, {:error, 401, code, description}) do
    conn
    |> put_resp_header("www-authenticate", ~s(Basic realm="sake"))
    |> error(401, code, description)
  end

  defp respond(conn, {:error, status, code, description}),
    do: error(conn, status, code, description)

  @doc false
  def parse(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} ->
        Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:urlencoded], pass: ["*/*"]))

      _ ->
        conn
    end
  end

  @doc false
  def json(conn, status, body) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(body))
  end

  @doc false
  def error(conn, status, code, description),
    do: json(conn, status, %{"error" => code, "error_description" => description})
end
