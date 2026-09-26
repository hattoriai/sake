defmodule Sake.Auth.Consent do
  @moduledoc """
  Renders the consent page and the authorization error page. The default,
  `Sake.Auth.Consent.Default`, ships its own small style sheet. A host
  replaces it with `consent: MyAppWeb.MCPConsent` in the auth config.

  `render/1` receives: `client_name`, `client_host` (nil when unknown),
  `redirect_host`, `loopback?`, `subject_display`, `scopes` (`[{name,
  description}]`), `request` (opaque, goes into a hidden field), `action`
  (the POST path), `csrf_token`, `issuer_name`. `render_error/1` receives
  `title`, `message`, `status`.

  A `Sake.Auth.Consent` struct is also a remembered approval of a client
  by a subject, held by `Sake.Auth.Store`.
  """

  @type t :: %__MODULE__{}
  defstruct [:subject_id, :client_id, :inserted_at, scopes: []]

  @callback render(map()) :: iodata()
  @callback render_error(map()) :: iodata()
end
