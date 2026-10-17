defmodule Sake.Auth.Page do
  @moduledoc false
  # What the two pages a person sees have in common, the authorize
  # endpoint's (`Sake.Auth.Authorize`) and the device verification page
  # (`Sake.Auth.DeviceVerification`): the form's body, its CSRF token, the
  # secret its hidden request is signed with, and the HTML answer, which
  # refuses to be framed.
  import Plug.Conn

  alias Sake.Auth.Config

  @doc "The conn with its urlencoded body parsed, unless the host's pipeline did it."
  @spec parse(Plug.Conn.t()) :: Plug.Conn.t()
  def parse(conn) do
    if match?(%Plug.Conn.Unfetched{}, conn.body_params),
      do: Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:urlencoded], pass: ["*/*"])),
      else: conn
  end

  @spec error(Plug.Conn.t(), Config.t(), pos_integer(), String.t(), String.t()) :: Plug.Conn.t()
  def error(conn, config, status, title, message) do
    html(
      conn,
      status,
      config.consent.render_error(%{title: title, message: message, status: status})
    )
  end

  @doc """
  The person signed in, but not as `requirement` asks (RFC 9470): the
  subject module's `reauthenticate/2` sends them to sign in again and
  back, or, without it, the error page says so.
  """
  @spec reauthenticate(
          Plug.Conn.t(),
          Config.t(),
          Sake.Auth.Authentication.requirement()
        ) :: Plug.Conn.t()
  def reauthenticate(conn, config, requirement) do
    if Sake.Auth.Subject.reauthenticates?(config.subject),
      do: config.subject.reauthenticate(conn, Map.take(requirement, [:acr_values, :max_age])),
      else:
        error(
          conn,
          config,
          401,
          "Sign in again to continue",
          "The app asks that you sign in again, or with a stronger method, before it is " <>
            "authorized. Sign in again, then start the connection again from the app."
        )
  end

  @spec html(Plug.Conn.t(), pos_integer(), iodata()) :: Plug.Conn.t()
  def html(conn, status, body) do
    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_header("content-security-policy", "frame-ancestors 'none'")
    |> send_resp(status, body)
  end

  @doc """
  The CSRF token for a form. `Plug.CSRFProtection` loads its state into
  the process dictionary when it runs; only then does a token exist that
  its own check accepts. Without it the field stays empty and the signed
  request blob is the defence.
  """
  @spec csrf_token() :: String.t()
  def csrf_token do
    if Process.get(:plug_csrf_token_per_host) != nil,
      do: Plug.CSRFProtection.get_csrf_token(),
      else: ""
  end

  @spec secret(Config.t()) :: binary()
  def secret(%Config{secret: secret}) when is_binary(secret), do: secret

  def secret(_config),
    do:
      raise(
        ArgumentError,
        "Sake needs a secret: start {Sake, secret_key_base: ...}, or set config :sake, :secret_key_base"
      )
end
