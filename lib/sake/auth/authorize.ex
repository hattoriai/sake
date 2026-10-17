defmodule Sake.Auth.Authorize do
  @moduledoc """
  The authorization endpoint: `GET` validates the request and shows the
  consent page (or redirects at once when consent is remembered); `POST`
  records the decision. Mount it inside the pipeline that requires a
  signed-in person; Sake reads the person through `Sake.Auth.Subject`.

  After it resolves the resource (the endpoint URL the token is for), it
  asks the subject module's optional `authorize_resource?/2` whether this
  person may authorize a client for it; a `false` answer sends the client
  `access_denied`. A remembered consent is kept per person, client and
  resource.

  The consent form is protected in two layers. The hidden `request` field
  is a signed blob bound to the signed-in person, and it expires after ten
  minutes: a form posted by anyone else, or later, is refused. When the
  host's pipeline runs `Plug.CSRFProtection` (`protect_from_forgery` in
  Phoenix), the form also carries the CSRF token and the host's plug
  checks it. A Plug-only host without CSRF middleware sends an empty
  `_csrf_token` field and relies on the signed blob alone.

  The consent and error pages refuse to be framed (`x-frame-options:
  DENY` and `content-security-policy: frame-ancestors 'none'`).
  """
  @behaviour Plug
  import Plug.Conn

  alias Sake.Auth
  alias Sake.Auth.{AuthorizationRequest, Config, Grant, Page}

  # The adapter: it reads the request and the signed-in person, asks
  # `Sake.Auth.AuthorizationRequest` and `Sake.Auth.Grant`, and renders
  # their answers as a redirect or a page. The consent form's signed
  # request and its CSRF token are its own.

  @salt "sake.authorize"
  @request_ttl 600

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{method: "GET"} = conn, _opts), do: start(conn, Auth.config())
  def call(%{method: "POST"} = conn, _opts), do: decide(conn, Auth.config())
  def call(conn, _opts), do: send_resp(conn, 405, "")

  # ---- GET

  defp start(conn, config) do
    conn = fetch_query_params(conn)
    p = conn.query_params

    case AuthorizationRequest.client(config, p["client_id"], p["redirect_uri"]) do
      {:ok, client} ->
        validated(conn, config, client, p)

      {:error, :unknown_client} ->
        error_page(
          conn,
          config,
          400,
          "Unknown client",
          "The app that sent you here is an unknown client. Nothing was authorized."
        )

      {:error, :client, reason} ->
        error_page(
          conn,
          config,
          400,
          "Client not accepted",
          "The app's client identity could not be verified (#{reason}). Nothing was authorized."
        )

      {:error, :redirect_uri} ->
        error_page(
          conn,
          config,
          400,
          "Redirect not allowed",
          "The app asked to send the code to a redirect address it did not register. Nothing was authorized."
        )
    end
  end

  defp validated(conn, config, client, p) do
    case AuthorizationRequest.validate(config, client, p) do
      {:ok, request} ->
        authenticated(conn, config, client, request)

      {:error, code, description} ->
        redirect_error(conn, config, p["redirect_uri"], code, description, p["state"])
    end
  end

  defp authenticated(conn, config, client, request) do
    case config.subject.from_conn(conn) do
      {:ok, principal} ->
        decided(
          conn,
          config,
          request,
          principal,
          Grant.decide(config, client, request, principal)
        )

      :error ->
        error_page(
          conn,
          config,
          401,
          "Sign in first",
          "Sign in to your account, then start the connection again from the app."
        )
    end
  end

  defp decided(conn, config, _request, principal, {:issue, request}) do
    {:ok, code} = Grant.issue(config, request, config.subject.id(principal))
    redirect_code(conn, config, request, code)
  end

  defp decided(conn, config, _request, principal, {:consent, %{request: request} = assigns}) do
    subject_id = config.subject.id(principal)
    blob = Plug.Crypto.sign(secret(config), @salt, %{request: request, subject_id: subject_id})

    assigns =
      Map.merge(assigns, %{request: blob, action: conn.request_path, csrf_token: csrf_token()})

    html(conn, 200, config.consent.render(assigns))
  end

  defp decided(conn, config, request, _principal, {:error, code, description}),
    do: redirect_error(conn, config, request.redirect_uri, code, description, request.state)

  # ---- POST

  defp decide(conn, config) do
    conn = Page.parse(conn)
    p = conn.body_params

    with {:ok, %{request: request, subject_id: subject_id}} <-
           Plug.Crypto.verify(secret(config), @salt, p["request"] || "", max_age: @request_ttl),
         {:ok, principal} <- config.subject.from_conn(conn),
         true <- config.subject.id(principal) == subject_id do
      decision(conn, config, p["decision"], request, subject_id)
    else
      _ ->
        error_page(
          conn,
          config,
          400,
          "Request expired",
          "This authorization request is no longer valid. Start again from the app."
        )
    end
  end

  defp decision(conn, config, "approve", request, subject_id) do
    {:ok, code} = Grant.approve(config, request, subject_id)
    redirect_code(conn, config, request, code)
  end

  defp decision(conn, config, _decision, request, _subject_id) do
    redirect_error(
      conn,
      config,
      request.redirect_uri,
      "access_denied",
      "The person denied the request",
      request.state
    )
  end

  # ---- codes

  @doc "Issues a code for `request` (a map with client_id, redirect_uri, code_challenge, scopes, resource) and `subject_id`; returns the plain code."
  @spec issue_code(Config.t(), map(), String.t()) :: String.t()
  defdelegate issue_code(config, request, subject_id), to: Grant

  # ---- responses

  defp redirect_code(conn, config, request, code) do
    redirect(conn, request.redirect_uri, %{
      "code" => code,
      "state" => request.state,
      "iss" => config.issuer
    })
  end

  defp redirect_error(conn, config, uri, code, description, state) do
    redirect(conn, uri, %{
      "error" => code,
      "error_description" => description,
      "state" => state,
      "iss" => config.issuer
    })
  end

  defp redirect(conn, uri, params) do
    params = Map.reject(params, fn {_, v} -> is_nil(v) end)
    location = uri |> URI.parse() |> URI.append_query(URI.encode_query(params)) |> URI.to_string()

    conn
    |> put_resp_header("location", location)
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(302, "")
  end

  defp error_page(conn, config, status, title, message),
    do: Page.error(conn, config, status, title, message)

  defp html(conn, status, body), do: Page.html(conn, status, body)
  defp csrf_token, do: Page.csrf_token()
  defp secret(config), do: Page.secret(config)
end
