defmodule Sake.Auth.Bearer do
  @moduledoc false
  # Validates the access token of an MCP request and loads the principal.
  #
  # A bearer token comes with the Bearer scheme (RFC 6750). A token bound
  # to a DPoP key comes with the DPoP scheme and a proof made with that
  # key for this very request (RFC 9449 §7.1); sent as a plain bearer
  # token it is refused, or a stolen one would work without the key. An
  # unbound token sent with the DPoP scheme is refused as well: the scheme
  # follows the token's binding, which the client learnt from the token
  # endpoint's `token_type`.
  #
  # The 401's challenges (RFC 9449 §7.1): a Bearer one, and a DPoP one
  # with the algorithms proofs may use when the server takes DPoP. The
  # one for the scheme the request used comes first and carries the
  # error, so a client that reads only the first sees what went wrong.
  #
  # With `dpop: [required: true]` only bound tokens are taken: the Bearer
  # scheme is refused even for an unbound token (so tokens issued before
  # the switch stop working), and a 401 offers the DPoP challenge alone,
  # since a challenge names a scheme the server would accept (RFC 9110
  # §11.6.1, RFC 9449 §7.1).

  import Plug.Conn

  alias Sake.Auth
  alias Sake.Auth.{DPoP, Resource, Tokens}

  @spec check(Plug.Conn.t(), map()) :: {:ok, Plug.Conn.t()} | {:error, Plug.Conn.t()}
  def check(conn, plug_opts) do
    config = Auth.config()
    resource = Resource.canonical(conn, plug_opts)

    with {:ok, scheme, token} <- credentials(conn, config),
         {:ok, record} <- record(config, scheme, token, resource),
         :ok <- possession(conn, config, scheme, token, record, resource),
         {:ok, principal} <- principal(config, record) do
      {:ok,
       conn
       |> nonce(config, scheme)
       |> assign(:sake_token, record)
       |> assign(:sake_scopes, record.scopes)
       |> assign(:sake_scope, principal)
       |> assign(:sake_dpop, scheme == :dpop)}
    else
      {:error, scheme, code, description} ->
        {:error, unauthorized(conn, config, {scheme, code, description})}

      _ ->
        {:error, unauthorized(conn, config, nil)}
    end
  end

  # The scheme name is case-insensitive (RFC 9110 §11.1); one space
  # separates it from the token.
  defp credentials(conn, config) do
    case get_req_header(conn, "authorization") do
      [header] -> scheme(header, config)
      _ -> :error
    end
  end

  defp scheme(<<scheme::binary-size(6), " ", token::binary>> = header, config)
       when token != "" do
    if String.downcase(scheme) == "bearer",
      do: {:ok, :bearer, token},
      else: dpop(header, config)
  end

  defp scheme(header, config), do: dpop(header, config)

  defp dpop(<<scheme::binary-size(4), " ", token::binary>>, config) when token != "" do
    cond do
      String.downcase(scheme) != "dpop" ->
        :error

      config.dpop == false ->
        {:error, :bearer, "invalid_request", "This server does not take the DPoP scheme"}

      true ->
        {:ok, :dpop, token}
    end
  end

  defp dpop(_header, _config), do: :error

  defp record(config, scheme, token, resource) do
    {module, state} = Auth.store(config)

    with {:ok, record} <- module.get_token(state, :access, Tokens.hash(token)),
         true <- Tokens.valid?(record, DateTime.utc_now()),
         true <- record.resource == resource do
      {:ok, record}
    else
      _ when scheme == :dpop -> {:error, :dpop, "invalid_token", "The access token is not valid"}
      _ -> :error
    end
  end

  defp possession(_conn, %{dpop: %{required: true}}, :bearer, _token, _record, _resource),
    do: {:error, :dpop, "invalid_token", "This server takes DPoP-bound tokens only"}

  defp possession(_conn, _config, :bearer, _token, %{jkt: nil}, _resource), do: :ok

  defp possession(_conn, _config, :bearer, _token, _record, _resource),
    do: {:error, :dpop, "invalid_token", "The access token is DPoP-bound: send it with a proof"}

  defp possession(_conn, %{dpop: %{required: true}}, :dpop, _token, %{jkt: nil}, _resource),
    do: {:error, :dpop, "invalid_token", "The access token is not DPoP-bound"}

  defp possession(_conn, _config, :dpop, _token, %{jkt: nil}, _resource),
    do:
      {:error, :bearer, "invalid_token", "The access token is not DPoP-bound: send it as Bearer"}

  # The proof may name the URL the request reached or the endpoint's
  # canonical resource: behind a proxy that terminates TLS, the request
  # this node sees is not the one the client made, and the resource is
  # what the host configured it to be.
  defp possession(conn, config, :dpop, token, record, resource) do
    with {:ok, proof} <- proof(conn),
         {:ok, jkt} <-
           DPoP.verify(proof,
             htm: conn.method,
             htu: [Resource.origin(conn) <> conn.request_path, resource],
             access_token: token,
             nonce: DPoP.nonce_secret(config)
           ) do
      if Plug.Crypto.secure_compare(jkt, record.jkt),
        do: :ok,
        else: {:error, :dpop, "invalid_dpop_proof", "The proof's key is not the token's"}
    else
      {:error, code, description} -> {:error, :dpop, code, description}
    end
  end

  defp proof(conn) do
    case DPoP.from_conn(conn) do
      :none -> {:error, "invalid_dpop_proof", "A DPoP-bound token needs a DPoP proof"}
      other -> other
    end
  end

  # A person's token loads its subject; a machine client's (it has none)
  # asks the subject module for the client's principal on every request,
  # so a client the host cuts off stops at once.
  defp principal(config, %{subject_id: nil, client_id: client_id}) do
    with {:ok, client} <- Sake.Auth.Clients.get(config, client_id),
         do: Sake.Auth.Subject.client_principal(config.subject, client)
  end

  defp principal(config, record), do: config.subject.fetch(record.subject_id)

  defp nonce(conn, config, :dpop), do: DPoP.put_nonce(conn, config)
  defp nonce(conn, _config, :bearer), do: conn

  defp unauthorized(conn, config, error) do
    params = [
      ~s(resource_metadata="#{Resource.metadata_url(conn)}"),
      ~s(scope="#{Resource.scopes_string(config)}")
    ]

    conn =
      case error do
        {:dpop, "use_dpop_nonce", _description} -> DPoP.put_nonce(conn, config)
        _ -> conn
      end

    conn
    |> prepend_resp_headers(
      for(c <- challenges(config, params, error), do: {"www-authenticate", c})
    )
    |> Sake.Plug.send_error(401, nil, Sake.JSONRPC.code(:invalid_request), "Unauthorized")
  end

  defp challenges(%{dpop: false}, params, error), do: [challenge(:bearer, params, error)]

  defp challenges(%{dpop: %{required: true}}, params, error),
    do: [challenge(:dpop, params, dpop_error(error))]

  defp challenges(_config, params, {:dpop, _code, _description} = error),
    do: [challenge(:dpop, params, error), challenge(:bearer, params, nil)]

  defp challenges(_config, params, error),
    do: [challenge(:bearer, params, error), challenge(:dpop, params, nil)]

  defp dpop_error({_scheme, code, description}), do: {:dpop, code, description}
  defp dpop_error(nil), do: nil

  defp challenge(scheme, params, {scheme, code, description}),
    do:
      challenge(
        scheme,
        [~s(error="#{code}"), ~s(error_description="#{description}") | params],
        nil
      )

  defp challenge(:bearer, params, _error), do: "Bearer " <> Enum.join(params, ", ")

  defp challenge(:dpop, params, _error),
    do: "DPoP " <> Enum.join(params ++ [~s(algs="#{Enum.join(DPoP.algs(), " ")}")], ", ")

  @doc """
  The 403 challenge for a component the token's scopes do not cover, in
  the scheme the token came with.
  """
  @spec insufficient_scope(Plug.Conn.t(), [String.t()]) :: Plug.Conn.t()
  def insufficient_scope(conn, scopes) do
    params = [
      ~s(error="insufficient_scope"),
      ~s(scope="#{Enum.join(scopes, " ")}"),
      ~s(resource_metadata="#{Resource.metadata_url(conn)}")
    ]

    scheme = if conn.assigns[:sake_dpop], do: :dpop, else: :bearer
    put_resp_header(conn, "www-authenticate", challenge(scheme, params, nil))
  end
end
