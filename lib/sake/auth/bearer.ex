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
  #
  # The token is Sake's own (`auth: true`), looked up by its hash in the
  # store, or an external authorization server's (`auth: name`), which
  # `Sake.Auth.External` verifies. Everything else here is the same for
  # both: the schemes, the DPoP binding, the challenges.
  #
  # A refusal is a `Sake.Auth.Challenge`; `Sake.Plug` sends it, with the
  # JSON-RPC error of an MCP endpoint as the body.
  #
  # Core: the request is described by a plain map (`t:request/0`), never
  # the conn; `Sake.Auth.authenticate/2` reads it from the conn and puts
  # the answer on it.

  alias Sake.Auth.{Challenge, Config, DPoP, External, Resource, Tokens}

  @typedoc """
  The request whose token is checked: the values of its `Authorization`
  and `DPoP` headers, its method, and the URL it reached (origin and
  path, without the query).
  """
  @type request :: %{
          authorization: [String.t()],
          dpop: [String.t()],
          method: String.t(),
          url: String.t()
        }

  @typedoc """
  An accepted token: its record, the scopes it holds now, its principal,
  whether it came with the DPoP scheme, and the DPoP nonce to send back
  (when the server requires them and it did).
  """
  @type accepted :: %{
          token: Sake.Auth.TokenRecord.t(),
          scopes: [String.t()],
          principal: term(),
          dpop: boolean(),
          nonce: String.t() | nil
        }

  @doc """
  Checks the token of `request` for the endpoint at `resource` (its
  canonical URL, the token's audience). `config` is Sake's own
  configuration or an external server's. `context` goes to an external
  server's `c:Sake.Auth.External.verify_token/2` as it is, and nowhere
  else.
  """
  @spec check(Config.t() | External.t(), request(), String.t(), term()) ::
          {:ok, accepted()} | {:error, Challenge.t()}
  def check(config, request, resource, context) do
    with {:ok, scheme, token} <- credentials(request, config),
         {:ok, record, found} <- record(config, scheme, token, resource, context),
         :ok <- possession(request, config, scheme, token, record, resource),
         {:ok, principal} <- principal(config, record, found) do
      {:ok,
       %{
         token: record,
         scopes: scopes(config, principal, record),
         principal: principal,
         dpop: scheme == :dpop,
         nonce: if(scheme == :dpop, do: DPoP.current_nonce(config))
       }}
    else
      {:error, scheme, code, description} ->
        {:error, unauthorized(request, config, {scheme, code, description})}

      _ ->
        {:error, unauthorized(request, config, nil)}
    end
  end

  # The scheme name is case-insensitive (RFC 9110 §11.1); one space
  # separates it from the token.
  defp credentials(request, config) do
    case request.authorization do
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

  defp record(%Config{} = config, scheme, token, resource, _context) do
    {module, state} = Sake.Auth.store(config)

    with {:ok, record} <- module.get_token(state, :access, Tokens.hash(token)),
         true <- Tokens.valid?(record, DateTime.utc_now()),
         true <- record.resource == resource do
      {:ok, record, nil}
    else
      _ -> invalid(scheme)
    end
  end

  defp record(%External{} = config, scheme, token, resource, context) do
    case External.verify(config, token, resource, context) do
      {:ok, record, found} -> {:ok, record, found}
      :error -> invalid(scheme)
    end
  end

  defp invalid(:dpop), do: {:error, :dpop, "invalid_token", "The access token is not valid"}
  defp invalid(:bearer), do: :error

  defp possession(_request, %{dpop: %{required: true}}, :bearer, _token, _record, _resource),
    do: {:error, :dpop, "invalid_token", "This server takes DPoP-bound tokens only"}

  defp possession(_request, _config, :bearer, _token, %{jkt: nil}, _resource), do: :ok

  defp possession(_request, _config, :bearer, _token, _record, _resource),
    do: {:error, :dpop, "invalid_token", "The access token is DPoP-bound: send it with a proof"}

  defp possession(_request, %{dpop: %{required: true}}, :dpop, _token, %{jkt: nil}, _resource),
    do: {:error, :dpop, "invalid_token", "The access token is not DPoP-bound"}

  defp possession(_request, _config, :dpop, _token, %{jkt: nil}, _resource),
    do:
      {:error, :bearer, "invalid_token", "The access token is not DPoP-bound: send it as Bearer"}

  # The proof may name the URL the request reached or the endpoint's
  # canonical resource: behind a proxy that terminates TLS, the request
  # this node sees is not the one the client made, and the resource is
  # what the host configured it to be.
  defp possession(request, config, :dpop, token, record, resource) do
    with {:ok, proof} <- proof(request),
         {:ok, jkt} <-
           DPoP.verify(proof,
             htm: request.method,
             htu: [request.url, resource],
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

  defp proof(request) do
    case DPoP.from_headers(request.dpop) do
      :none -> {:error, "invalid_dpop_proof", "A DPoP-bound token needs a DPoP proof"}
      other -> other
    end
  end

  # A person's token loads its subject; a machine client's (it has none)
  # asks the subject module for the client's principal on every request,
  # so a client the host cuts off stops at once.
  #
  # An external server's token stands for what `Sake.Auth.External` says.
  defp principal(%External{} = config, record, found),
    do: External.principal(config, record, found)

  defp principal(config, %{subject_id: nil, client_id: client_id}, nil) do
    with {:ok, client} <- Sake.Auth.Clients.get(config, client_id),
         do: Sake.Auth.Subject.client_principal(config.subject, client)
  end

  defp principal(config, record, nil), do: config.subject.fetch(record.subject_id)

  # The token's scopes, narrowed to those its principal may hold now
  # (`c:Sake.Auth.Subject.scopes_for/2`), so a person whose role changed
  # loses a scope before the token expires. An external server's token
  # holds what that server granted.
  defp scopes(%External{}, _principal, record), do: record.scopes

  defp scopes(config, principal, record),
    do:
      Sake.Auth.Subject.permitted_scopes(
        config.subject,
        principal,
        record.resource,
        record.scopes
      )

  # The challenges go out in order, the one with the error first; a
  # `use_dpop_nonce` error comes with the nonce to use.
  defp unauthorized(request, config, error) do
    metadata = Resource.metadata_url(request.url)
    scopes = Resource.scopes_string(config)
    params = [~s(resource_metadata="#{metadata}"), ~s(scope="#{scopes}")]
    [first | _] = headers = challenges(config, params, error)

    {code, description} =
      case error do
        {_scheme, code, description} -> {code, description}
        nil -> {nil, nil}
      end

    %Challenge{
      status: 401,
      www_authenticate: headers,
      scheme: first |> String.split(" ", parts: 2) |> hd(),
      resource_metadata: metadata,
      scope: String.split(scopes, " ", trim: true),
      error: code,
      error_description: description,
      nonce: if(code == "use_dpop_nonce", do: DPoP.current_nonce(config))
    }
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
  The 401 challenge (RFC 9470 §3) for a component that asks for a
  stronger or more recent sign-in than the token's: `acr_values` and
  `max_age` say what it asks, in the scheme the token came with
  (`dpop?`). `scopes`, when the token lacks some of the component's
  scopes as well, are named in its `scope`, so that one new grant covers
  both.
  """
  @spec insufficient_user_authentication(
          String.t(),
          %{acr_values: [String.t()], max_age: non_neg_integer() | nil},
          :acr | :max_age,
          [String.t()],
          boolean()
        ) :: Challenge.t()
  def insufficient_user_authentication(url, requirement, reason, scopes, dpop?) do
    metadata = Resource.metadata_url(url)
    acr_values = Enum.join(requirement.acr_values, " ")

    params =
      [
        ~s(error="insufficient_user_authentication"),
        ~s(error_description="#{user_authentication_description(reason)}")
      ] ++
        if(acr_values == "", do: [], else: [~s(acr_values="#{acr_values}")]) ++
        if(requirement.max_age == nil, do: [], else: [~s(max_age="#{requirement.max_age}")]) ++
        if(scopes == [], do: [], else: [~s(scope="#{Enum.join(scopes, " ")}")]) ++
        [~s(resource_metadata="#{metadata}")]

    scheme = if dpop?, do: :dpop, else: :bearer

    %Challenge{
      status: 401,
      www_authenticate: [challenge(scheme, params, nil)],
      scheme: if(scheme == :dpop, do: "DPoP", else: "Bearer"),
      resource_metadata: metadata,
      scope: scopes,
      acr_values: requirement.acr_values,
      max_age: requirement.max_age,
      error: "insufficient_user_authentication",
      error_description: user_authentication_description(reason)
    }
  end

  # RFC 9470 §3's two examples: the class of the sign-in, or its age.
  defp user_authentication_description(:acr), do: "A different authentication level is required"
  defp user_authentication_description(:max_age), do: "More recent authentication is required"

  @doc """
  The 403 challenge for a component the token's scopes do not cover, at
  the endpoint `url` reached, in the scheme the token came with (`dpop?`).
  """
  @spec insufficient_scope(String.t(), [String.t()], boolean()) :: Challenge.t()
  def insufficient_scope(url, scopes, dpop?) do
    metadata = Resource.metadata_url(url)

    params = [
      ~s(error="insufficient_scope"),
      ~s(scope="#{Enum.join(scopes, " ")}"),
      ~s(resource_metadata="#{metadata}")
    ]

    scheme = if dpop?, do: :dpop, else: :bearer

    %Challenge{
      status: 403,
      www_authenticate: [challenge(scheme, params, nil)],
      scheme: if(scheme == :dpop, do: "DPoP", else: "Bearer"),
      resource_metadata: metadata,
      scope: scopes,
      error: "insufficient_scope"
    }
  end
end
