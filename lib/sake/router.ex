if Code.ensure_loaded?(Phoenix.Router) do
  defmodule Sake.Router do
    @moduledoc """
    Router macros for Phoenix hosts:

        import Sake.Router

        scope "/" do
          sake_well_known()
        end

        scope "/oauth" do
          pipe_through :api
          sake_oauth_api()
        end

        scope "/oauth" do
          pipe_through [:browser, :require_authenticated_user]
          sake_oauth_authorize()
        end

        scope "/:org_slug" do
          sake_endpoint "/mcp", server: MyApp.MCP, auth: true
        end

    The authorize routes (with the device verification page, for
    `device:`) go inside the pipeline that requires a signed-in person;
    the API routes (the pushed authorization request endpoint among them,
    for `par:`, and the JWKS and userinfo endpoints, for `openid:`) need
    no session; the well-known routes need no
    pipeline at all; the endpoint needs no pipeline either (Sake checks the
    bearer token itself).

    An endpoint whose tokens come from another authorization server names
    its `external_auth:` configuration (see `Sake.Auth.External`), and
    needs only the well-known routes, for its protected resource metadata:

        scope "/" do
          sake_well_known()
          sake_endpoint "/partners/mcp", server: MyApp.MCP, auth: :keycloak
        end
    """

    defmacro sake_well_known do
      quote do
        Phoenix.Router.forward("/.well-known", Sake.Auth.WellKnown)
      end
    end

    defmacro sake_oauth_api do
      quote do
        Phoenix.Router.post("/token", Sake.Auth.Token, [])
        Phoenix.Router.post("/register", Sake.Auth.DCR, [])
        Phoenix.Router.post("/revoke", Sake.Auth.Revoke, [])
        Phoenix.Router.post("/device_authorization", Sake.Auth.DeviceAuthorization, [])
        Phoenix.Router.post("/par", Sake.Auth.PushedAuthorization, [])
        Phoenix.Router.get("/jwks", Sake.Auth.PublicKeys, [])
        Phoenix.Router.get("/userinfo", Sake.Auth.UserInfo, [])
        Phoenix.Router.post("/userinfo", Sake.Auth.UserInfo, [])
      end
    end

    defmacro sake_oauth_authorize(opts \\ []) do
      quote do
        Phoenix.Router.get("/authorize", Sake.Auth.Authorize, unquote(opts))
        Phoenix.Router.post("/authorize", Sake.Auth.Authorize, unquote(opts))
        Phoenix.Router.get("/device", Sake.Auth.DeviceVerification, unquote(opts))
        Phoenix.Router.post("/device", Sake.Auth.DeviceVerification, unquote(opts))
      end
    end

    @doc "Mounts a Sake endpoint at `path` with the `Sake.Plug` options; works under a scope with a dynamic segment."
    defmacro sake_endpoint(path, opts) do
      quote do
        Phoenix.Router.match(:*, unquote(path), Sake.Plug, unquote(opts))
      end
    end
  end
end
