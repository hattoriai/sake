defmodule Sake.Auth.Revoke do
  @moduledoc "The revocation endpoint (RFC 7009). Revoking a refresh token revokes its whole family."
  @behaviour Plug
  import Plug.Conn

  alias Sake.Auth
  alias Sake.Auth.{ClientAuth, Tokens}

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{method: "POST"} = conn, _opts) do
    config = Auth.config()
    conn = Sake.Auth.Token.parse(conn)
    p = conn.body_params

    # A revoke call that names no client at all has nothing to authenticate
    # against; it is answered like an unknown token, without a 401.
    if client_given?(conn, p) do
      authenticate_and_revoke(conn, config, p)
    else
      ok(conn)
    end
  end

  def call(conn, _opts), do: send_resp(conn, 405, "")

  defp authenticate_and_revoke(conn, config, p) do
    case ClientAuth.authenticate(config, conn, p) do
      {:error, :invalid_client} ->
        conn
        |> put_resp_header("www-authenticate", ~s(Basic realm="sake"))
        |> Sake.Auth.Token.error(401, "invalid_client", "Client authentication failed")

      {:ok, client} ->
        if is_binary(p["token"]),
          do: revoke(config, client, Tokens.hash(p["token"]), p["token_type_hint"])

        ok(conn)
    end
  end

  defp client_given?(conn, p),
    do:
      match?(["Basic " <> _], get_req_header(conn, "authorization")) or is_binary(p["client_id"])

  defp ok(conn), do: conn |> put_resp_header("cache-control", "no-store") |> send_resp(200, "")

  defp revoke(config, client, hash, hint) do
    {module, state} = Auth.store(config)
    order = if hint == "access_token", do: [:access, :refresh], else: [:refresh, :access]
    Enum.each(order, &revoke_owned(module, state, client, hash, &1))
  end

  defp revoke_owned(module, state, client, hash, kind) do
    with {:ok, %{client_id: cid} = record} <- module.get_token(state, kind, hash),
         true <- cid == client.id do
      revoke_record(module, state, kind, record)
    else
      _ -> :ok
    end
  end

  defp revoke_record(module, state, :refresh, record),
    do: module.revoke_family(state, record.family_id)

  defp revoke_record(module, state, _kind, record), do: module.revoke_token(state, record.id)
end
