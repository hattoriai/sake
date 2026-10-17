defmodule Sake.Auth.RouterPlug do
  @moduledoc """
  The token, registration, revocation, device authorization and pushed
  authorization request endpoints as one Plug router for hosts without
  Phoenix:

      forward "/oauth", to: Sake.Auth.RouterPlug

  Mount `Sake.Auth.Authorize` yourself, behind your session and login
  plugs, at `/oauth/authorize`, and with `device:`
  `Sake.Auth.DeviceVerification` the same way, at `/oauth/device`.
  """
  use Plug.Router

  plug :match
  plug :dispatch

  post "/token", to: Sake.Auth.Token
  post "/register", to: Sake.Auth.DCR
  post "/revoke", to: Sake.Auth.Revoke
  post "/device_authorization", to: Sake.Auth.DeviceAuthorization
  post "/par", to: Sake.Auth.PushedAuthorization
  match _, do: send_resp(conn, 404, "")
end
