defmodule SakeTest.PhoenixEndpoint do
  @moduledoc false
  # A host as `mix phx.new` generates it: the body is parsed by the
  # endpoint before any route runs, and the session is a signed cookie.
  use Phoenix.Endpoint, otp_app: :sake

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: JSON

  plug Plug.MethodOverride
  plug Plug.Head

  plug Plug.Session,
    store: :cookie,
    key: "_sake_test_key",
    signing_salt: "sake-test",
    same_site: "Lax"

  plug SakeTest.PhoenixRouter
end

defmodule SakeTest.ErrorJSON do
  @moduledoc false
  def render(template, _assigns),
    do: %{"error" => Phoenix.Controller.status_message_from_template(template)}
end
