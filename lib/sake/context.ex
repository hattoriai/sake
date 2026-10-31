defmodule Sake.Context do
  @moduledoc """
  What a component learns about the request it serves.

  `scope` is the host's principal (the current user, organization, or
  anything the host puts there); `token` and `scopes` are set when the
  endpoint has authorization; `inputs` holds the client's answers
  (elicitation, sampling, roots) on a retry; `progress` reports progress
  to the client when it asked for it; `task` is the task ID when the
  component runs as a task (see `Sake.Tasks`); `assigns` holds what the
  server's middleware decided for this request (see `Sake.Middleware`).

  `client_info` is the client's `clientInfo`, such as
  `%{"name" => "claude-code", "version" => "2.1.0"}`: on the modern
  protocol, from the request's `_meta`; on a legacy session, from its
  `initialize`. Over HTTP (`Sake.Plug`), and in `Sake.Test`, a legacy
  session keeps only its `name`, `title` and `version`, which ride in the
  signed session ID. It is `%{}` when the client sent none.

  `base_url` is the URL of the MCP endpoint the request reached, as the
  client reaches it: scheme, host, the port when it is not the scheme's
  default, and the endpoint's path, without a query or a trailing slash
  (`"https://example.com/acme/mcp"`). A tool builds absolute URLs to its
  own host from it, such as a link the person opens or a one-time upload
  URL:

      def execute(%{name: name}, ctx) do
        uri = URI.parse(ctx.base_url)
        token = MyApp.Uploads.grant(ctx.scope, name)
        {:ok, %{upload_url: URI.to_string(%{uri | path: "/uploads/" <> token})}}
      end

  `Sake.Plug` sets it from the request; on an endpoint with `auth: true`
  its origin is the issuer's, as for the token's audience, and on an
  external authorization server with `url:`, that `url:`'s (see
  `Sake.Auth.External`). Behind a proxy that does not rewrite the
  request, put `Plug.RewriteOn` before the endpoint (see "Behind a proxy"
  in the security guide). It is `nil` where there is no HTTP request:
  over stdio (`Sake.Stdio`) and in `Sake.Test`'s in-memory client unless
  the test passes `base_url:`, so a tool that needs it should say so when
  it is missing.

  `server` is the server the component belongs to: for a component of a
  mounted server, that server, not the one the client reached.
  `prefixes` are the prefixes of the mounts between them, innermost
  first (`nil` for a mount without one): `[]` when the client reached the
  component's own server. An MCP App resolves the names the client knows
  its tools and resources by from them, with `Sake.UI.tool_name/2` and
  `Sake.UI.resource_uri/2`.
  """

  @type t :: %__MODULE__{}

  defstruct era: :modern,
            protocol_version: "2026-07-28",
            client_info: %{},
            client_capabilities: %{},
            scope: nil,
            token: nil,
            scopes: [],
            request_id: nil,
            method: nil,
            trace: %{},
            log_level: nil,
            inputs: %{},
            assigns: %{},
            conn_assigns: %{},
            progress: nil,
            server: nil,
            transport: nil,
            task: nil,
            secret: nil,
            reraise: false,
            base_url: nil,
            prefixes: []

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    ctx = struct!(__MODULE__, opts)
    %{ctx | progress: ctx.progress || fn _current, _total_and_message -> :ok end}
  end
end
