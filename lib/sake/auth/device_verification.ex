defmodule Sake.Auth.DeviceVerification do
  @moduledoc """
  The device verification page (RFC 8628 §3.3), at `{oauth_path}/device`:
  where a person enters the user code a CLI or a device shows them, then
  approves or denies its request on the consent page. Mount it, like
  `Sake.Auth.Authorize`, inside the pipeline that requires a signed-in
  person; Sake reads the person through `Sake.Auth.Subject`. It answers
  404 without `device:` in the auth config.

  `GET` shows the code entry form (`c:Sake.Auth.Consent.render_user_code/1`),
  prefilled from `verification_uri_complete`'s `user_code`; nothing is
  looked up until the person submits it. A posted code shows the
  consent page, with the code on it to compare with the device's. A
  code that is unknown, expired or already decided is refused with the
  same message, and each signed-in person may enter five codes a minute,
  which is what keeps the eight characters of a user code out of reach
  of guessing. The consent page shows even when the person approved the
  client before: whoever started the request may have sent the code to
  someone else to approve.

  Both forms carry a signed blob bound to the signed-in person, which
  expires after ten minutes, and the host's CSRF token when its pipeline
  runs `Plug.CSRFProtection`, as `Sake.Auth.Authorize`'s form does. The
  pages refuse to be framed.
  """
  @behaviour Plug
  import Plug.Conn

  alias Sake.Auth
  alias Sake.Auth.{Device, Page}

  # The adapter: it reads the user code and the signed-in person, asks
  # `Sake.Auth.Device`, and renders the code entry form, the consent page
  # or the outcome.

  @entry_salt "sake.device.entry"
  @consent_salt "sake.device.consent"
  @form_ttl 600

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts), do: call(conn, opts, Auth.config())

  defp call(conn, _opts, %{device: false}), do: send_resp(conn, 404, "")

  defp call(%{method: "GET"} = conn, _opts, config) do
    conn = fetch_query_params(conn)

    signed_in(conn, config, fn principal ->
      entry(conn, config, principal, 200, conn.query_params["user_code"], nil)
    end)
  end

  defp call(%{method: "POST"} = conn, _opts, config) do
    conn = Page.parse(conn)
    p = conn.body_params

    signed_in(conn, config, fn principal ->
      case p["decision"] do
        nil -> submitted(conn, config, principal, p)
        decision -> decided(conn, config, principal, p, decision)
      end
    end)
  end

  defp call(conn, _opts, _config), do: send_resp(conn, 405, "")

  defp signed_in(conn, config, fun) do
    case config.subject.from_conn(conn) do
      {:ok, principal} ->
        fun.(principal)

      :error ->
        Page.error(
          conn,
          config,
          401,
          "Sign in first",
          "Sign in to your account, then enter the code from your device again."
        )
    end
  end

  # ---- the code

  defp entry(conn, config, principal, status, user_code, error) do
    subject_id = config.subject.id(principal)

    assigns = %{
      user_code: if(is_binary(user_code), do: user_code, else: ""),
      error: error,
      subject_display: config.subject.display(principal),
      request: Plug.Crypto.sign(Page.secret(config), @entry_salt, %{subject_id: subject_id}),
      action: conn.request_path,
      csrf_token: Page.csrf_token(),
      issuer_name: config.name
    }

    Page.html(conn, status, Auth.Consent.render_user_code(config.consent, assigns))
  end

  defp submitted(conn, config, principal, p) do
    subject_id = config.subject.id(principal)

    with {:ok, %{subject_id: ^subject_id}} <- verify(config, @entry_salt, p["request"]),
         :ok <- Device.attempt(config, subject_id) do
      prompted(conn, config, principal, p["user_code"])
    else
      :limited ->
        entry(
          conn,
          config,
          principal,
          429,
          p["user_code"],
          "Too many codes entered. Wait a minute, then try again."
        )

      _ ->
        expired(conn, config)
    end
  end

  defp prompted(conn, config, principal, user_code) do
    case Device.prompt(config, user_code, principal) do
      {:consent, assigns} ->
        blob =
          Plug.Crypto.sign(Page.secret(config), @consent_salt, %{
            user_code: user_code,
            subject_id: config.subject.id(principal)
          })

        assigns =
          Map.merge(assigns, %{
            request: blob,
            action: conn.request_path,
            csrf_token: Page.csrf_token()
          })

        Page.html(conn, 200, config.consent.render(assigns))

      :error ->
        invalid(conn, config, principal, user_code)

      {:error, _code, description} ->
        Page.error(conn, config, 403, "Not allowed", description <> ". Nothing was authorized.")
    end
  end

  defp invalid(conn, config, principal, user_code) do
    entry(
      conn,
      config,
      principal,
      400,
      user_code,
      "That code is not valid. Check it, or start again on your device."
    )
  end

  # ---- the decision

  defp decided(conn, config, principal, p, decision) do
    subject_id = config.subject.id(principal)

    case verify(config, @consent_salt, p["request"]) do
      {:ok, %{user_code: user_code, subject_id: ^subject_id}} ->
        outcome(conn, config, principal, user_code, decision)

      _ ->
        expired(conn, config)
    end
  end

  defp outcome(conn, config, principal, user_code, "approve") do
    case Device.decide(config, user_code, principal, :approve) do
      :ok ->
        Page.error(conn, config, 200, "Device connected", "You can return to your device now.")

      :error ->
        invalid(conn, config, principal, user_code)

      {:error, _code, description} ->
        Page.error(conn, config, 403, "Not allowed", description <> ". Nothing was authorized.")
    end
  end

  defp outcome(conn, config, principal, user_code, _deny) do
    case Device.decide(config, user_code, principal, :deny) do
      :ok -> Page.error(conn, config, 200, "Request denied", "Nothing was authorized.")
      :error -> invalid(conn, config, principal, user_code)
    end
  end

  defp verify(config, salt, blob) when is_binary(blob),
    do: Plug.Crypto.verify(Page.secret(config), salt, blob, max_age: @form_ttl)

  defp verify(_config, _salt, _blob), do: :error

  defp expired(conn, config) do
    Page.error(
      conn,
      config,
      400,
      "Request expired",
      "This page is no longer valid. Enter the code from your device again."
    )
  end
end
