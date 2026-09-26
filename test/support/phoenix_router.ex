defmodule SakeTest.PhoenixRouter do
  @moduledoc false
  use Phoenix.Router
  import Phoenix.Controller, only: [protect_from_forgery: 2, put_secure_browser_headers: 2]
  import Sake.Router

  pipeline :browser do
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :session do
    plug :fetch_session
  end

  scope "/" do
    sake_well_known()
  end

  scope "/oauth" do
    sake_oauth_api()
  end

  scope "/oauth" do
    pipe_through(:browser)
    sake_oauth_authorize()
  end

  # Test-only sign-in: puts the person's id in the session.
  scope "/" do
    pipe_through(:session)
    get "/test-login/:user_id", SakeTest.PhoenixRouter.Login, []
  end

  scope "/:org" do
    sake_endpoint("/mcp", server: SakeDev.Server, auth: true, secret: String.duplicate("s", 64))
  end

  defmodule Login do
    @moduledoc false
    @behaviour Plug
    import Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, _opts) do
      conn |> put_session(:user_id, conn.path_params["user_id"]) |> send_resp(204, "")
    end
  end
end
