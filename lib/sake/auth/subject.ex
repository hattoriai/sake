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

  @optional_callbacks authorize_resource?: 2,
                      scopes_for: 2,
                      client_principal: 1,
                      assertion_principal: 2

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
