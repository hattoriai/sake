defmodule Sake.Auth.External do
  @moduledoc """
  An endpoint whose tokens come from an authorization server Sake does not
  run: your app's own OAuth provider (ExOauth2Provider, Boruta, a
  hand-rolled one) or an external identity provider (Keycloak, Auth0,
  Okta, Entra ID, Cognito, WorkOS). Sake is then only the resource server:
  it checks the tokens that server issues and enforces the scopes.

  Name each authorization server in the `Sake` child, and point an
  endpoint at it by name:

      {Sake,
       secret_key_base: ...,
       external_auth: [
         keycloak: [
           issuer: "https://sso.example.com/realms/acme",
           verify: :jwt,
           servers: [MyApp.MCP]
         ]
       ]}

      sake_endpoint "/mcp", server: MyApp.MCP, auth: :keycloak

  `Sake.Auth` (`auth: [...]`) is not needed at all; with it, one endpoint
  may take Sake's own tokens (`auth: true`) and another an external
  server's.

  ## Options

    * `:issuer` (required) — the authorization server's issuer
      identifier, exactly as its tokens' `iss` and its metadata say it
      (Auth0's ends with a slash). The protected resource metadata
      names it in `authorization_servers`, so MCP clients discover it as
      they would Sake's own.
    * `:verify` (required) — how a token is checked:
      * `:jwt` — a JWT access token (RFC 9068), verified with the
        issuer's keys: `:jwks` (a JWK Set map) or `:jwks_uri`, or else
        the `jwks_uri` of the issuer's OpenID Connect or RFC 8414
        metadata. Needs the optional `jose` dependency.
      * `{:introspection, opts}` — token introspection (RFC 7662) at
        `endpoint:`, authenticated as the resource with `client_id:`
        and `client_secret:` (`auth_method:` `:basic`, the default, or
        `:post`). An active answer is cached for `cache:` seconds
        (default 60, `0` turns the cache off), never past the token's
        `exp`, keyed by a digest of the token.
      * a module that implements `c:verify_token/2`, or a function of
        two arguments (`{module, function}` or a capture): your own
        code, for a provider that runs in your app.
    * `:audiences` — the `aud` values a token must carry one of. By
      default the endpoint's own URL, the resource the client asked for
      (RFC 8707). `:any` turns the audience check off; see the security
      note in the external authorization guide before you do.
    * `:typ` — the `typ` header a JWT access token must have: default
      `"at+jwt"` (RFC 9068). Many identity providers issue plain
      `"JWT"` access tokens; say so, or `:any`.
    * `:principal` — what a token stands for, as the endpoint's
      `ctx.scope`: a function of the verified claims (string keys) that
      returns `{:ok, principal}` or `:error` (a function of one
      argument, or `{module, function}`). By default the claims
      themselves.
    * `:servers` — the servers whose scopes the resource metadata lists
      in `scopes_supported` and challenges name, as for `Sake.Auth`.
    * `:resources` — the endpoint paths this server protects (with
      `:param` segments), so the protected resource metadata at each
      path names the right issuer. Needed whenever Sake knows more than
      one authorization server (`Sake.Auth` and this one, or several
      external ones).
    * `:dpop` — as for `Sake.Auth`: `true` (the default, when `jose` is
      there), `false`, or `[nonce: boolean, required: boolean]`. A
      token bound to a key (`cnf.jkt`) is only ever accepted with a
      proof made with that key.
    * `:extensions` — the authorization extensions to declare in the
      endpoint's MCP capabilities (`:client_credentials`,
      `:enterprise`), when this server offers their grants. Default
      none.
    * `:resource_name` — the protected resource metadata's
      `resource_name`.
    * `:allow_insecure` — allow `http` URLs (issuer, keys, introspection
      endpoint), for development and tests.

  ## The token

  Whichever way it was verified, a token becomes the same
  `Sake.Auth.TokenRecord` a token of `Sake.Auth` does, in `ctx.token`:
  `scopes` from `scope` (or `scp`, a string or a list), `client_id` from
  `client_id` (or `azp`), `subject_id` from `sub`, `jkt` from `cnf.jkt`,
  `expires_at` from `exp`, and `issuer` and `claims` besides. A token
  without `sub`, or whose `sub` is its client (RFC 9068 §2.2, the client
  credentials grant), is a machine client's: `subject_id` is `nil`.
  Scope checks, step-up challenges, middleware, and task ownership work
  as for Sake's own tokens; tasks and request states are bound to the
  issuer as well as the subject, so the same `sub` from another issuer
  is someone else.

  Each refusal is the telemetry event `[:sake, :auth, :external,
  :refused]`, with the configuration's `name`, its `issuer` and the
  `reason` (`:invalid_audience`, `:expired`, `:bad_signature`,
  `:inactive`, ...), for finding out why a token is not accepted.
  """

  alias Sake.Auth.{Config, JWKS, JWT, Resource, TokenRecord}
  alias Sake.Auth.External.Introspection

  @doc """
  Verifies a token for a provider that runs in your app. Return the
  token's claims, in the shape of an introspection answer (RFC 7662
  §2.2, string or atom keys): `sub`, `client_id`, `scope` (a string or a
  list), `exp` (seconds or a `DateTime`), `aud`, `cnf` with `jkt` for a
  DPoP-bound token. `{:ok, claims, principal}` gives the principal as
  well, when the query that found the token loaded it, and skips
  `principal:`. `:error` refuses the token.
  """
  @callback verify_token(token :: String.t(), conn :: Plug.Conn.t()) ::
              {:ok, map()} | {:ok, map(), term()} | :error

  @type t :: %__MODULE__{}

  defstruct [
    :name,
    :issuer,
    :verify,
    :jwks,
    :jwks_uri,
    :principal,
    :resources,
    :resource_name,
    audiences: nil,
    typ: "at+jwt",
    servers: [],
    dpop: true,
    extensions: [],
    allow_insecure: false,
    # The Sake secret, for DPoP nonces: `Sake` puts it here when it starts.
    secret: nil
  ]

  @extensions [:client_credentials, :enterprise]

  @doc "The external authorization server configured under `name`; raises when there is none."
  @spec fetch!(atom()) :: t()
  def fetch!(name) do
    case configs() do
      %{^name => config} ->
        config

      _ ->
        raise "Sake.Plug auth: #{inspect(name)} names no external_auth: configuration of {Sake, ...}"
    end
  end

  @doc false
  # The configurations `Sake.Auth.Supervisor` was started with.
  @spec configs() :: %{atom() => t()}
  def configs, do: :persistent_term.get({__MODULE__, :configs}, %{})

  @doc false
  # The `external_auth:` option of the `Sake` child, checked at start
  # (`Sake` calls it). Without `resources:` a configuration answers for
  # every path, which is only unambiguous when it is the one
  # authorization server Sake knows.
  @spec new_all(keyword(), Config.t() | nil) :: %{atom() => t()}
  def new_all(opts, auth) do
    configs = Map.new(opts, fn {name, config} -> {name, new(name, config)} end)

    if map_size(configs) + if(auth, do: 1, else: 0) > 1 do
      for {name, %{resources: nil}} <- configs,
          do:
            raise(
              ArgumentError,
              "external_auth: #{inspect(name)} needs resources: (the endpoint paths it protects) when Sake has more than one authorization server"
            )
    end

    configs
  end

  @doc false
  @spec new(atom(), keyword()) :: t()
  def new(name, opts) do
    if name in [nil, true, false] or not is_atom(name),
      do: raise(ArgumentError, "external_auth: names are atoms, got #{inspect(name)}")

    config = struct!(__MODULE__, Keyword.put(opts, :name, name))
    label = "external_auth: #{inspect(name)}"

    unless is_binary(config.issuer), do: raise(ArgumentError, "#{label} needs an issuer: URL")
    url!(config, config.issuer, "#{label} issuer:")

    %{
      config
      | verify: verify(config, config.verify, label),
        audiences: audiences(config.audiences, label),
        typ: typ(config.typ, label),
        principal: principal_option(config.principal, label),
        dpop: Config.dpop_option(config.dpop, config.secret),
        extensions: extensions(config.extensions, label)
    }
  end

  defp verify(config, :jwt, label) do
    JWT.require!("#{label} verify: :jwt")
    if config.jwks_uri, do: url!(config, config.jwks_uri, "#{label} jwks_uri:")
    :jwt
  end

  defp verify(config, {:introspection, opts}, label),
    do: {:introspection, Introspection.options(config, opts, label)}

  defp verify(_config, fun, _label) when is_function(fun, 2), do: {:callback, fun}

  defp verify(_config, {module, fun}, label) when is_atom(module) and is_atom(fun),
    do: {:callback, exported!(module, fun, 2, label, "verify:")}

  defp verify(_config, module, label) when is_atom(module) and module not in [nil, true, false],
    do: {:callback, exported!(module, :verify_token, 2, label, "verify:")}

  defp verify(_config, other, label),
    do:
      raise(
        ArgumentError,
        "#{label} verify: is :jwt, {:introspection, opts}, a module with verify_token/2 or a function of two arguments, got #{inspect(other)}"
      )

  defp exported!(module, fun, arity, label, option) do
    Code.ensure_loaded(module)

    unless function_exported?(module, fun, arity),
      do: raise(ArgumentError, "#{label} #{option} #{inspect(module)} has no #{fun}/#{arity}")

    Function.capture(module, fun, arity)
  end

  defp audiences(nil, _label), do: nil
  defp audiences(:any, _label), do: :any

  defp audiences(list, label) do
    unless is_list(list) and list != [] and Enum.all?(list, &is_binary/1),
      do: raise(ArgumentError, "#{label} audiences: is a list of strings, or :any")

    list
  end

  defp typ(:any, _label), do: nil
  defp typ(typ, _label) when is_binary(typ), do: typ

  defp typ(other, label),
    do: raise(ArgumentError, "#{label} typ: is a string or :any, got #{inspect(other)}")

  defp principal_option(nil, _label), do: nil
  defp principal_option(fun, _label) when is_function(fun, 1), do: fun

  defp principal_option({module, fun}, label) when is_atom(module) and is_atom(fun),
    do: exported!(module, fun, 1, label, "principal:")

  defp principal_option(other, label),
    do:
      raise(
        ArgumentError,
        "#{label} principal: is a function of one argument or {module, function}, got #{inspect(other)}"
      )

  defp extensions(list, label) do
    unless is_list(list) and list -- @extensions == [],
      do:
        raise(ArgumentError, "#{label} extensions: is a list of :client_credentials, :enterprise")

    list
  end

  @doc false
  # A URL Sake fetches or names: https, or http with `allow_insecure`.
  @spec url!(t(), term(), String.t()) :: :ok
  def url!(config, url, label) do
    scheme = is_binary(url) && URI.parse(url).scheme

    unless scheme == "https" or (config.allow_insecure and scheme == "http"),
      do:
        raise(
          ArgumentError,
          "#{label} must be an https URL (or allow_insecure: true in development)"
        )

    :ok
  end

  @doc false
  # The configuration whose `resources:` cover an endpoint path, for its
  # protected resource metadata; one without `resources:` covers them all.
  @spec for_path(String.t()) :: t() | nil
  def for_path(path) do
    configs()
    |> Map.values()
    |> Enum.find(fn
      %{resources: nil} -> true
      %{resources: patterns} -> Enum.any?(patterns, &Resource.path_match?(&1, path))
    end)
  end

  @doc false
  # The authorization extensions an endpoint on this server declares, for
  # its capabilities (`Sake.Server.Dispatch` calls it).
  @spec extensions(t()) :: [:client_credentials | :enterprise]
  def extensions(%__MODULE__{extensions: names}), do: names

  # ---- verification

  @doc false
  # The token's record for the endpoint at `resource`, and the principal
  # when the host's callback already found it.
  @spec verify(t(), String.t(), String.t(), Plug.Conn.t()) ::
          {:ok, TokenRecord.t(), {:principal, term()} | nil} | :error
  def verify(config, token, resource, conn) do
    with {:ok, claims, found} <- claims(config, config.verify, token, conn),
         {:ok, record} <- record(config, claims, resource) do
      {:ok, record, found}
    else
      {:error, reason} -> refused(config, reason)
    end
  end

  # RFC 9068 §4: the signature with the issuer's keys, `typ`, `iss`, and
  # the times. Only asymmetric algorithms are accepted (see
  # `Sake.Auth.JWT`), so an HMAC token "signed" with a public key is
  # refused like any unknown algorithm.
  defp claims(config, :jwt, token, _conn) do
    with {:ok, claims} <-
           JWKS.verify(config, token, keys(config),
             typ: config.typ,
             iss: config.issuer,
             required: ["exp"]
           ),
         do: {:ok, claims, nil}
  end

  defp claims(config, {:introspection, opts}, token, _conn) do
    with {:ok, claims} <- Introspection.introspect(config, opts, token), do: {:ok, claims, nil}
  end

  defp claims(_config, {:callback, fun}, token, conn) do
    case fun.(token, conn) do
      {:ok, claims} when is_map(claims) -> current(normalize(claims), nil)
      {:ok, claims, principal} when is_map(claims) -> current(normalize(claims), principal)
      _ -> {:error, :refused_by_callback}
    end
  end

  defp keys(%{jwks: %{} = jwks}), do: {:jwks, jwks}
  defp keys(%{jwks_uri: uri}) when is_binary(uri), do: {:uri, uri}
  defp keys(%{issuer: issuer}), do: {:issuer, issuer}

  # The callback's own answer is trusted, but not past its expiry.
  defp current(claims, principal) do
    if expired?(claims, System.system_time(:second)),
      do: {:error, :expired},
      else: {:ok, claims, principal && {:principal, principal}}
  end

  @doc false
  @spec expired?(map(), integer()) :: boolean()
  def expired?(claims, now) do
    case claims["exp"] do
      nil -> false
      exp when is_number(exp) -> exp <= now
      _ -> true
    end
  end

  # The callback may answer with atom keys, and an expiry as a DateTime.
  defp normalize(claims) do
    claims
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.update(
      "cnf",
      nil,
      &if(is_map(&1), do: Map.new(&1, fn {k, v} -> {to_string(k), v} end))
    )
    |> Map.update("exp", nil, fn
      %DateTime{} = at -> DateTime.to_unix(at)
      exp -> exp
    end)
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  # The checks every way of verifying shares: the issuer when the claims
  # name one, and the audience, which a token must have unless the host
  # said `audiences: :any`. A token for another resource of the same
  # authorization server is someone else's to accept.
  defp record(config, claims, resource) do
    cond do
      Map.has_key?(claims, "iss") and claims["iss"] != config.issuer ->
        {:error, :invalid_issuer}

      not audience?(config.audiences, claims["aud"], resource) ->
        {:error, :invalid_audience}

      true ->
        {:ok, to_record(config, claims, resource)}
    end
  end

  defp audience?(:any, _aud, _resource), do: true
  defp audience?(nil, aud, resource), do: audience?([resource], aud, resource)

  defp audience?(accepted, aud, _resource),
    do: aud |> List.wrap() |> Enum.any?(&(is_binary(&1) and &1 in accepted))

  defp to_record(config, claims, resource) do
    client_id = string(claims["client_id"]) || string(claims["azp"])
    sub = string(claims["sub"])

    %TokenRecord{
      kind: :access,
      client_id: client_id,
      subject_id: if(sub != client_id, do: sub),
      scopes: scopes(claims),
      resource: resource,
      jkt: claims |> Map.get("cnf") |> jkt(),
      expires_at: expires_at(claims["exp"]),
      issuer: config.issuer,
      claims: claims
    }
  end

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: nil

  defp scopes(%{"scope" => scope}) when is_binary(scope) or is_list(scope), do: scope_list(scope)
  defp scopes(%{"scp" => scope}), do: scope_list(scope)
  defp scopes(_claims), do: []

  defp scope_list(scope) when is_binary(scope), do: String.split(scope)
  defp scope_list(scope) when is_list(scope), do: Enum.filter(scope, &is_binary/1)
  defp scope_list(_scope), do: []

  defp jkt(%{"jkt" => jkt}) when is_binary(jkt), do: jkt
  defp jkt(_cnf), do: nil

  defp expires_at(exp) when is_integer(exp), do: DateTime.from_unix!(exp)
  defp expires_at(exp) when is_float(exp), do: DateTime.from_unix!(trunc(exp))
  defp expires_at(_exp), do: nil

  defp refused(config, reason) do
    :telemetry.execute(
      [:sake, :auth, :external, :refused],
      %{system_time: System.system_time()},
      %{
        name: config.name,
        issuer: config.issuer,
        reason: reason
      }
    )

    :error
  end

  @doc false
  # The principal a verified token stands for: the callback's, when it
  # found one, else `principal:`, else the claims.
  @spec principal(t(), TokenRecord.t(), {:principal, term()} | nil) :: {:ok, term()} | :error
  def principal(_config, _record, {:principal, principal}), do: {:ok, principal}
  def principal(%__MODULE__{principal: nil}, record, nil), do: {:ok, record.claims}

  def principal(%__MODULE__{principal: fun} = config, record, nil) do
    case fun.(record.claims) do
      {:ok, principal} -> {:ok, principal}
      _ -> refused(config, :no_principal)
    end
  end
end
