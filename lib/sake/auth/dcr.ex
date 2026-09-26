defmodule Sake.Auth.DCR do
  @moduledoc """
  Dynamic Client Registration (RFC 7591) for clients that do not use Client
  ID Metadata Documents. Public clients only; no authentication. Put a rate
  limit in front of it.

  A client that sends no `grant_types` is registered for both the
  authorization code and the refresh token grants, and the response says
  so.
  """
  @behaviour Plug
  import Plug.Conn

  alias Sake.Auth.{Client, Redirect, Tokens}

  @grant_types ["authorization_code", "refresh_token"]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{method: "POST"} = conn, _opts) do
    config = Sake.Auth.config()

    if config.dcr do
      with {:ok, doc, conn} when is_map(doc) <- Sake.Plug.Body.json(conn, 65_536),
           {:ok, client} <- build(doc) do
        {module, state} = Sake.Auth.store(config)
        :ok = module.put_client(state, client)

        response = %{
          "client_id" => client.id,
          "client_id_issued_at" => System.system_time(:second),
          "client_name" => client.name,
          "redirect_uris" => client.redirect_uris,
          "grant_types" => client.grant_types,
          "response_types" => ["code"],
          "token_endpoint_auth_method" => "none",
          "application_type" => client.application_type
        }

        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_content_type("application/json")
        |> send_resp(201, JSON.encode!(response))
      else
        {:error, code} when is_binary(code) -> error(conn, code)
        _ -> error(conn, "invalid_client_metadata")
      end
    else
      send_resp(conn, 404, "")
    end
  end

  def call(conn, _opts), do: send_resp(conn, 405, "")

  defp build(doc) do
    with :ok <- validate(doc) do
      {:ok, client_from(doc)}
    end
  end

  defp validate(doc) do
    with :ok <- validate_redirect_uris(doc["redirect_uris"]),
         :ok <- validate_name(doc["client_name"] || "Unnamed client"),
         :ok <- validate_auth_method(doc["token_endpoint_auth_method"]),
         :ok <- validate_types(doc) do
      validate_grants(doc["grant_types"] || @grant_types)
    end
  end

  defp validate_types(doc) do
    if Sake.Auth.Clients.metadata_types_valid?(doc),
      do: :ok,
      else: {:error, "invalid_client_metadata"}
  end

  defp validate_redirect_uris(uris) do
    cond do
      not (is_list(uris) and uris != [] and Enum.all?(uris, &Redirect.valid?/1)) ->
        {:error, "invalid_redirect_uri"}

      length(uris) > 10 ->
        {:error, "invalid_client_metadata"}

      true ->
        :ok
    end
  end

  defp validate_name(name) do
    if is_binary(name) and String.length(name) in 1..100,
      do: :ok,
      else: {:error, "invalid_client_metadata"}
  end

  defp validate_auth_method(method) do
    if (method || "none") == "none", do: :ok, else: {:error, "invalid_client_metadata"}
  end

  defp validate_grants(grants) do
    if is_list(grants) and grants -- @grant_types == [],
      do: :ok,
      else: {:error, "invalid_client_metadata"}
  end

  defp client_from(doc) do
    %Client{
      id: "dc_" <> Tokens.generate(),
      name: doc["client_name"] || "Unnamed client",
      kind: :dynamic,
      redirect_uris: doc["redirect_uris"],
      grant_types: doc["grant_types"] || @grant_types,
      token_endpoint_auth_method: "none",
      client_uri: doc["client_uri"],
      logo_uri: doc["logo_uri"],
      scopes: if(is_binary(doc["scope"]), do: String.split(doc["scope"]), else: nil),
      application_type: doc["application_type"] || "native"
    }
  end

  defp error(conn, code) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(400, JSON.encode!(%{"error" => code}))
  end
end
