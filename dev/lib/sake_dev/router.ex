defmodule SakeDev.Router do
  @moduledoc false
  # The development server: a login form with a session cookie, the OAuth
  # endpoints, protected endpoints at /mcp, /acme/mcp and /beta/mcp, and an
  # open one at /open/mcp.

  defmodule RequireLogin do
    @moduledoc false
    use Plug.Builder
    plug :require_login
    plug Sake.Auth.Authorize

    def require_login(conn, _) do
      if get_session(conn, :user_id) do
        conn
      else
        return_to = conn.request_path <> "?" <> conn.query_string

        conn
        |> put_resp_header("location", "/login?" <> URI.encode_query(%{"return_to" => return_to}))
        |> send_resp(302, "")
        |> halt()
      end
    end
  end

  use Plug.Router

  plug Plug.Logger
  plug :put_secret_key_base
  plug Plug.Session, store: :cookie, key: "_sake_dev", signing_salt: "sake-dev", same_site: "Lax"
  plug :fetch_session
  plug :match
  plug Plug.Parsers, parsers: [:urlencoded], pass: ["*/*"]
  plug :dispatch

  get "/", do: SakeDev.Pages.home(conn)

  get "/login", do: SakeDev.Pages.login(conn, safe_return_to(conn.query_params["return_to"]))

  post "/login" do
    return_to = safe_return_to(conn.body_params["return_to"])

    case SakeDev.Accounts.authenticate(conn.body_params["email"], conn.body_params["password"]) do
      {:ok, person} ->
        conn
        |> put_session(:user_id, person.id)
        |> redirect_to(return_to)

      :error ->
        SakeDev.Pages.login(conn, return_to, "Wrong email or password")
    end
  end

  post "/logout", do: conn |> configure_session(drop: true) |> redirect_to("/")

  forward "/.well-known", to: Sake.Auth.WellKnown
  forward "/oauth/authorize", to: SakeDev.Router.RequireLogin
  forward "/oauth", to: Sake.Auth.RouterPlug

  # A conformance or CLI client sends no Origin header at all, which is
  # always allowed regardless of `origins:`. A browser hitting this from
  # the dev server's own page is the one legitimate Origin to allow;
  # anything else (an evil DNS-rebinding Origin, an evil Host) must be
  # refused, which needs an explicit list here, not `:any`.
  forward "/open/mcp",
    to: Sake.Plug,
    init_opts: [server: SakeDev.ConformanceServer, origins: ["http://localhost:4000"]]

  forward "/mcp", to: Sake.Plug, init_opts: [server: SakeDev.Server, auth: true]
  forward "/acme/mcp", to: Sake.Plug, init_opts: [server: SakeDev.Server, auth: true]
  forward "/beta/mcp", to: Sake.Plug, init_opts: [server: SakeDev.Server, auth: true]

  match _, do: send_resp(conn, 404, "Not found")

  defp redirect_to(conn, to), do: conn |> put_resp_header("location", to) |> send_resp(302, "")

  # Only a same-app path is a safe `return_to`: `//evil.example/x` is a
  # protocol-relative URL a browser follows as `https://evil.example/x`,
  # and anything with a scheme is an absolute URL to somewhere else
  # entirely. Anything that isn't a single leading `/` falls back to `/`.
  defp safe_return_to("/" <> rest) do
    if String.starts_with?(rest, "/"), do: "/", else: "/" <> rest
  end

  defp safe_return_to(_), do: "/"

  # The cookie store signs with the same secret Sake uses.
  defp put_secret_key_base(conn, _), do: %{conn | secret_key_base: Sake.Secret.fetch!()}
end
