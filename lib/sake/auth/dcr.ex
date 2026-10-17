defmodule Sake.Auth.DCR do
  @moduledoc false
  # The registration endpoint's adapter (RFC 7591): it reads the metadata
  # document, hands it to `Sake.Auth.Registration`, and renders the
  # answer. No authentication; put a rate limit in front of it.
  @behaviour Plug
  import Plug.Conn

  alias Sake.Auth.Registration

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{method: "POST"} = conn, _opts) do
    config = Sake.Auth.config()

    if config.dcr do
      # Every answer goes out on the conn the body read returned: the one
      # `call/2` was given is stale once the body has been read.
      case Sake.Auth.Body.json(conn, 65_536) do
        {:ok, doc, conn} -> respond(conn, Registration.register(config, doc))
        {:error, _reason, conn} -> error(conn, "invalid_client_metadata")
      end
    else
      send_resp(conn, 404, "")
    end
  end

  def call(conn, _opts), do: send_resp(conn, 405, "")

  defp respond(conn, {:ok, response}) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(201, JSON.encode!(response))
  end

  defp respond(conn, {:error, code}), do: error(conn, code)

  defp error(conn, code) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(400, JSON.encode!(%{"error" => code}))
  end
end
