defmodule Sake.Auth.Consent do
  @moduledoc """
  Renders the consent page and the authorization error page. The default,
  `Sake.Auth.Consent.Default`, ships its own small style sheet. A host
  replaces it with `consent: MyAppWeb.MCPConsent` in the auth config.

  `render/1` receives: `flow` (`:authorization_code`, or `:device` for
  the device verification page), `client_name`, `client_host` (nil when
  unknown), `redirect_host` and `loopback?` (both nil for `:device`,
  where nothing is redirected), `user_code` (for `:device`, the code the
  person entered, to compare with the one on their device; nil
  otherwise), `subject_display`, `scopes` (`[{name, description}]`),
  `resource` (the endpoint URL the token will be for), `request`
  (opaque, goes into a hidden field), `action` (the POST path),
  `csrf_token` (empty when the host runs no CSRF middleware),
  `issuer_name`. Post the form's `decision` as `approve` or `deny`.

  `render_error/1` receives `title`, `message`, `status`; the device
  verification page also shows its final message with it, with status
  200.

  The optional `c:render_user_code/1` is the device verification page's
  code entry form (`Sake.Auth.Consent.Default`'s when a module does not
  define it). It receives `user_code` (the code to prefill, from
  `verification_uri_complete`, or `""`), `error` (why the last code was
  refused, or nil), `subject_display`, `request` (opaque, goes into a
  hidden field), `action`, `csrf_token` and `issuer_name`; the form
  posts `user_code`.

  A `Sake.Auth.Consent` struct is also a remembered approval of a client
  by a subject for one resource, held by `Sake.Auth.Store`.
  """

  alias Sake.Auth.Consent.Default

  @type t :: %__MODULE__{}
  defstruct [:subject_id, :client_id, :resource, :inserted_at, scopes: []]

  @callback render(map()) :: iodata()
  @callback render_error(map()) :: iodata()
  @callback render_user_code(map()) :: iodata()
  @optional_callbacks render_user_code: 1

  @doc false
  # The code entry page of `module`, or the default one.
  @spec render_user_code(module(), map()) :: iodata()
  def render_user_code(module, assigns) do
    Code.ensure_loaded(module)

    if function_exported?(module, :render_user_code, 1),
      do: module.render_user_code(assigns),
      else: Default.render_user_code(assigns)
  end
end
