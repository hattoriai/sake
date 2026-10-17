defmodule Sake.Auth.Subject do
  @moduledoc """
  How Sake finds the person behind a request. The host implements it:

      defmodule MyAppWeb.MCPSubject do
        @behaviour Sake.Auth.Subject
        def from_conn(conn), do: with(%{user: user} <- conn.assigns[:current_scope], do: {:ok, user}, else: (_ -> :error))
        def id(user), do: user.id
        def fetch(id), do: MyApp.Accounts.fetch_user(id)
        def display(user), do: user.email
      end

  Sake stores only the string ID.

  The optional `c:authorize_resource?/2` decides whether this person may
  authorize a client for an endpoint URL; without it, every signed-in
  person may. A multi-tenant host uses it to refuse a token for a tenant
  the person does not belong to (see the tenants guide). It is asked
  again, with the principal `fetch/1` loads, on every refresh: a person
  it now refuses (or whom `fetch/1` no longer finds) cannot renew the
  grant, and every token of it is revoked. An access token already
  issued lasts until it expires.

  The optional `c:scopes_for/2` decides which of the server's scopes this
  person may hold for an endpoint URL: a list of scopes, or `:all`;
  without it, every scope. Sake grants the scopes a client asks for, so
  without it a person who may use the endpoint at all gets every scope
  there is (a viewer gets `issues:write` as an admin does). With it:

    * the authorize page grants, and the consent page shows, only the
      requested scopes the person may hold, and refuses the request with
      `access_denied` when none is left;
    * a JWT grant or a machine client's token gets only those of its
      principal;
    * a refresh renews the grant with only those the person may still
      hold;
    * every request narrows the token's scopes to them, with the
      principal `fetch/1` has just loaded, so a person whose role
      changes loses a scope at once, before the access token expires.

  It runs on every request, as `fetch/1` does: keep it as cheap. It does
  not apply to the tokens of an external authorization server
  (`Sake.Auth.External`), whose scopes are that server's to grant.

  Two more optional callbacks let tokens be issued without a person at
  the browser, and refuse by default:

    * `c:client_principal/1` — the principal a machine client acts as,
      for the client credentials grant. It is asked when a token is
      issued and again on every request the token makes, so returning
      `:error` cuts the client off at once. Such a token has no subject:
      its `subject_id` is `nil`, and `client_id` names the client.
    * `c:assertion_principal/2` — the person (or workload) a JWT grant
      from a trusted issuer stands for: the claims of a verified
      enterprise ID-JAG, or of a workload identity token, and the
      `Sake.Auth.TrustedIssuer` that issued it. The token's subject is
      `id/1` of the principal returned, so `fetch/1` loads it on every
      request as for anyone else.

  ## How the person signed in

  Sake does not sign anyone in, nor run multi-factor authentication: the
  host's login does. Two optional callbacks tell Sake how it went, for
  the tools that ask for a strong or a recent sign-in (RFC 9470, see
  "Step-up authentication" in the authorization guide):

    * `c:authentication/1` — how and when the person signed in to the
      session of this request: `%{acr: acr, auth_time: datetime}`, the
      authentication context class (`"mfa"`, `"pwd"`, or whatever names
      your login gives its methods) and the time of that sign-in, either
      `nil` when unknown. The authorize endpoint and the device
      verification page ask it when the person approves a request, and
      the code or the device grant carries the answer into the tokens; a
      refresh keeps it, since a refresh is no new sign-in. Default
      `%{acr: nil, auth_time: nil}`.
    * `c:reauthenticate/2` — send the person to sign in again (or to
      complete MFA), then back to the current URL (`conn.request_path`
      and `conn.query_string`, with `GET`). The authorize endpoint and
      the device verification page call it when a client asks for
      `acr_values` or a `max_age` that `c:authentication/1`'s answer does
      not meet; the second argument says what was asked:
      `%{acr_values: [acr], max_age: seconds | nil}`. Coming back with a
      sign-in that still does not meet it calls it again: make sure the
      sign-in it sends the person to can. Default: an error page, "Sign in
      again to continue", which ends the request there.

  ## Who the person is (OpenID Connect)

  With `openid:` (see `Sake.Auth.Config`), a client granted the `openid`
  scope gets an ID token naming the person by `c:id/1` (its `sub`), and
  may ask the userinfo endpoint for more. The optional `c:claims/2` says
  what: the claims of the person for the scopes granted (`profile`,
  `email`), as a map of OpenID Connect claim names (`"name"`, `"email"`,
  `"email_verified"`, ...) to JSON values. Sake never reads your user
  schema: what it returns is all a client learns. Default: no claims
  but `sub`.

  `c:scopes_for/2` applies to these scopes as to any other: a host whose
  `scopes_for/2` returns a list withholds `openid`, `profile` and
  `email` unless the list names them.
  """

  @callback from_conn(Plug.Conn.t()) :: {:ok, term()} | :error
  @callback id(term()) :: String.t()
  @callback fetch(String.t()) :: {:ok, term()} | :error
  @callback display(term()) :: String.t()

  @doc "Whether this person may authorize a client for this endpoint URL, or renew such a grant; default true."
  @callback authorize_resource?(principal :: term(), resource :: String.t()) :: boolean()

  @doc "The scopes this person may hold for this endpoint URL, or `:all`; default `:all`."
  @callback scopes_for(principal :: term(), resource :: String.t()) :: [String.t()] | :all

  @doc "The principal a machine client acts as (client credentials); `:error` refuses it."
  @callback client_principal(client :: Sake.Auth.Client.t()) :: {:ok, term()} | :error

  @doc "The account a verified JWT grant stands for; `:error` refuses it."
  @callback assertion_principal(claims :: map(), issuer :: Sake.Auth.TrustedIssuer.t()) ::
              {:ok, term()} | :error

  @doc "How and when the person of this request signed in; default `%{acr: nil, auth_time: nil}`."
  @callback authentication(Plug.Conn.t()) :: %{
              acr: String.t() | nil,
              auth_time: DateTime.t() | nil
            }

  @doc "Sends the person to sign in again, as asked, and back to the current URL; default an error page."
  @callback reauthenticate(
              Plug.Conn.t(),
              %{acr_values: [String.t()], max_age: non_neg_integer() | nil}
            ) :: Plug.Conn.t()

  @doc "The person's OpenID Connect claims for the granted scopes (`profile`, `email`); default none."
  @callback claims(principal :: term(), scopes :: [String.t()]) :: map()

  @optional_callbacks authorize_resource?: 2,
                      scopes_for: 2,
                      client_principal: 1,
                      assertion_principal: 2,
                      authentication: 1,
                      reauthenticate: 2,
                      claims: 2

  @doc false
  # How the person of `conn` signed in, normalized; unknown without
  # `authentication/1`.
  @spec authentication(module(), Plug.Conn.t()) :: Sake.Auth.Authentication.context()
  def authentication(subject, conn) do
    if exported?(subject, :authentication, 1),
      do: Sake.Auth.Authentication.context(subject.authentication(conn)),
      else: Sake.Auth.Authentication.none()
  end

  @doc false
  # The person's claims for `scopes`, with string keys: none without
  # `claims/2`, and none from an answer that is not a map.
  @spec claims(module(), term(), [String.t()]) :: map()
  def claims(subject, principal, scopes) do
    with true <- exported?(subject, :claims, 2),
         %{} = claims <- subject.claims(principal, scopes) do
      Map.new(claims, fn {name, value} -> {to_string(name), value} end)
    else
      _ -> %{}
    end
  end

  @doc false
  # Whether the subject module sends people to sign in again itself.
  @spec reauthenticates?(module()) :: boolean()
  def reauthenticates?(subject), do: exported?(subject, :reauthenticate, 2)

  @doc false
  # The optional callbacks, refusing when the host did not define them.
  @spec client_principal(module(), Sake.Auth.Client.t()) :: {:ok, term()} | :error
  def client_principal(subject, client) do
    if exported?(subject, :client_principal, 1),
      do: ok_or_error(subject.client_principal(client)),
      else: :error
  end

  @doc false
  @spec assertion_principal(module(), map(), Sake.Auth.TrustedIssuer.t()) ::
          {:ok, term()} | :error
  def assertion_principal(subject, claims, issuer) do
    if exported?(subject, :assertion_principal, 2),
      do: ok_or_error(subject.assertion_principal(claims, issuer)),
      else: :error
  end

  @doc false
  @spec authorize_resource?(module(), term(), String.t()) :: boolean()
  def authorize_resource?(subject, principal, resource) do
    if exported?(subject, :authorize_resource?, 2),
      do: subject.authorize_resource?(principal, resource) == true,
      else: true
  end

  @doc false
  # `scopes` narrowed to those the principal may hold for `resource`, in
  # their order; anything but a list or `:all` from the host holds none.
  @spec permitted_scopes(module(), term(), String.t(), [String.t()]) :: [String.t()]
  def permitted_scopes(subject, principal, resource, scopes) do
    if exported?(subject, :scopes_for, 2) do
      case subject.scopes_for(principal, resource) do
        :all -> scopes
        allowed when is_list(allowed) -> Enum.filter(scopes, &(&1 in allowed))
        _other -> []
      end
    else
      scopes
    end
  end

  defp exported?(subject, fun, arity) do
    Code.ensure_loaded(subject)
    function_exported?(subject, fun, arity)
  end

  defp ok_or_error({:ok, principal}), do: {:ok, principal}
  defp ok_or_error(_other), do: :error
end
