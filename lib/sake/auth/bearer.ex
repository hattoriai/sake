defmodule Sake.Auth.Bearer do
  @moduledoc false
  # Validates the bearer token of an MCP request and loads the principal.

  import Plug.Conn

  alias Sake.Auth
  alias Sake.Auth.{Resource, Tokens}

  @spec check(Plug.Conn.t(), map()) :: {:ok, Plug.Conn.t()} | {:error, Plug.Conn.t()}
  def check(conn, plug_opts) do
    config = Auth.config()
    {module, state} = Auth.store(config)
    resource = Resource.canonical(conn, plug_opts)

    with [header] <- get_req_header(conn, "authorization"),
         {:ok, token} <- token(header),
         {:ok, record} <- module.get_token(state, :access, Tokens.hash(token)),
         true <- Tokens.valid?(record, DateTime.utc_now()),
         true <- record.resource == resource,
         {:ok, principal} <- config.subject.fetch(record.subject_id) do
      {:ok,
       conn
       |> assign(:sake_token, record)
       |> assign(:sake_scopes, record.scopes)
       |> assign(:sake_scope, principal)}
    else
      _ -> {:error, unauthorized(conn, config)}
    end
  end

  # The scheme name is case-insensitive (RFC 9110 §11.1); one space
  # separates it from the token.
  defp token(<<scheme::binary-size(6), " ", token::binary>>) when token != "" do
    if String.downcase(scheme) == "bearer", do: {:ok, token}, else: :error
  end

  defp token(_header), do: :error

  defp unauthorized(conn, config) do
    challenge =
      ~s(Bearer resource_metadata="#{Resource.metadata_url(conn)}", scope="#{Resource.scopes_string(config)}")

    conn
    |> put_resp_header("www-authenticate", challenge)
    |> Sake.Plug.send_error(401, nil, Sake.JSONRPC.code(:invalid_request), "Unauthorized")
  end

  @doc "The 403 challenge for a component the token's scopes do not cover."
  @spec insufficient_scope(Plug.Conn.t(), [String.t()]) :: Plug.Conn.t()
  def insufficient_scope(conn, scopes) do
    put_resp_header(
      conn,
      "www-authenticate",
      ~s(Bearer error="insufficient_scope", scope="#{Enum.join(scopes, " ")}", resource_metadata="#{Resource.metadata_url(conn)}")
    )
  end
end
