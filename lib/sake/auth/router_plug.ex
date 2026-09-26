defmodule Sake.Auth.RouterPlug do
  @moduledoc """
  The token, registration and revocation endpoints as one Plug router for
  hosts without Phoenix:

      forward "/oauth", to: Sake.Auth.RouterPlug

  Mount `Sake.Auth.Authorize` yourself, behind your session and login plugs.
  """
  use Plug.Router

  plug :match
  plug :dispatch

  post "/token", to: Sake.Auth.Token
  post "/register", to: Sake.Auth.DCR
  post "/revoke", to: Sake.Auth.Revoke
  match _, do: send_resp(conn, 404, "")
end
