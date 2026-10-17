defmodule SakeDev.Router do
  @moduledoc false
  # The development server: a login form with a session cookie, the OAuth
  # endpoints, protected endpoints at /mcp, /acme/mcp and /beta/mcp, an
  # open one at /open/mcp, and a protected gateway at /gateway/mcp that
  # mounts the example server and proxies the open one.

  defmodule RequireLogin do
    @moduledoc false
    use Plug.Builder
    plug :require_login
    plug Sake.Auth.Authorize

    def require_login(conn, _), do: SakeDev.Router.require_login(conn)
  end

  defmodule RequireLoginDevice do
    @moduledoc false
    use Plug.Builder
    plug :require_login
    plug Sake.Auth.DeviceVerification

    def require_login(conn, _), do: SakeDev.Router.require_login(conn)
  end

  use Plug.Router

  # The login wall in front of the pages a person sees: the authorize
  # endpoint and the device verification page.
  @doc false
  def require_login(conn) do
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

  plug Plug.Logger
  plug :put_secret_key_base
  plug Plug.Session, store: :cookie, key: "_sake_dev", signing_salt: "sake-dev", same_site: "Lax"
  plug :fetch_session
  plug :match
  plug Plug.Parsers, parsers: [:urlencoded], pass: ["*/*"]
  plug :dispatch

  get "/", do: SakeDev.Pages.home(conn)

  get "/login",
    do:
      SakeDev.Pages.login(
        conn,
        safe_return_to(conn.query_params["return_to"]),
        nil,
        conn.query_params["acr"] == "mfa"
      )

  # The sign-in records how it went (RFC 9470): "mfa" with the one-time
  # code, "pwd" without, and when.
  post "/login" do
    return_to = safe_return_to(conn.body_params["return_to"])

    case SakeDev.Accounts.authenticate(conn.body_params["email"], conn.body_params["password"]) do
      {:ok, person} ->
        acr = if conn.body_params["otp"] == SakeDev.Accounts.otp(), do: "mfa", else: "pwd"

        conn
        |> put_session(:user_id, person.id)
        |> put_session(:acr, acr)
        |> put_session(:auth_time, System.system_time(:second))
        |> redirect_to(return_to)

      :error ->
        SakeDev.Pages.login(conn, return_to, "Wrong email or password")
    end
  end

  post "/logout", do: conn |> configure_session(drop: true) |> redirect_to("/")

  forward "/.well-known", to: Sake.Auth.WellKnown
  forward "/oauth/authorize", to: SakeDev.Router.RequireLogin
  forward "/oauth/device", to: SakeDev.Router.RequireLoginDevice
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
  forward "/gateway/mcp", to: Sake.Plug, init_opts: [server: SakeDev.Gateway, auth: true]

  match _, do: send_resp(conn, 404, "Not found")

  defp redirect_to(conn, to), do: conn |> put_resp_header("location", to) |> send_resp(302, "")

  # Only a same-app path is a safe `return_to`. Rejected outright, each
  # falling back to `/`:
  #   - anything not starting with `/`, or whose second character is `/`
  #     or `\` (`//evil.example` and `/\evil.example` are both
  #     protocol-relative URLs a browser follows to `evil.example` —
  #     browsers treat `\` exactly like `/` in an http(s) URL);
  #   - a `\` anywhere else in the value (same reason, mid-path);
  #   - a control character (`\r`, `\n`, `\t`, or any byte below `0x20`) —
  #     a header/response-splitting vector;
  #   - a `:` before the first `?` — a scheme cannot appear in a path, so
  #     this also catches `javascript:...` and an absolute URL with no
  #     leading slash removed by the checks above.
  defp safe_return_to(to) when is_binary(to) do
    if safe_path?(to), do: to, else: "/"
  end

  defp safe_return_to(_), do: "/"

  defp safe_path?(to) do
    String.starts_with?(to, "/") and String.at(to, 1) not in ["/", "\\"] and
      not String.contains?(to, "\\") and
      not Enum.any?(String.to_charlist(to), &(&1 < 0x20)) and
      not scheme_before_query?(to)
  end

  defp scheme_before_query?(to),
    do: to |> String.split("?", parts: 2) |> hd() |> String.contains?(":")

  # The cookie store signs with the same secret Sake uses.
  defp put_secret_key_base(conn, _), do: %{conn | secret_key_base: Sake.Secret.fetch!()}
end
