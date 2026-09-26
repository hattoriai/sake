defmodule SakeTest.PhoenixRouter do
  @moduledoc false
  use Phoenix.Router
  import Sake.Router

  pipeline :browser do
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

  scope "/:org" do
    sake_endpoint("/mcp", server: SakeDev.Server, auth: true, secret: String.duplicate("s", 64))
  end
end
