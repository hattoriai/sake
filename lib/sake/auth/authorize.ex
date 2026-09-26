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
  alias Sake.Auth.{Clients, Config, Redirect, Tokens}

  @salt "sake.authorize"
  @request_ttl 600
  @code_ttl 600

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

    with {:ok, client} <- client(config, p["client_id"]),
         :ok <- redirect_uri(client, p["redirect_uri"]) do
      validated(conn, config, client, p)
    else
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
    case validate(config, client, p) do
      {:ok, request} ->
        authenticated(conn, config, client, request)

      {:error, code, description} ->
        redirect_error(conn, config, p["redirect_uri"], code, description, p["state"])
    end
  end

  defp authenticated(conn, config, client, request) do
    case config.subject.from_conn(conn) do
      {:ok, principal} ->
        if authorize_resource?(config.subject, principal, request.resource),
          do: consent_or_issue(conn, config, client, request, principal),
          else:
            redirect_error(
              conn,
              config,
              request.redirect_uri,
              "access_denied",
              "You may not authorize this resource",
              request.state
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

  defp authorize_resource?(subject, principal, resource) do
    Code.ensure_loaded(subject)

    if function_exported?(subject, :authorize_resource?, 2),
      do: subject.authorize_resource?(principal, resource) == true,
      else: true
  end

  defp client(config, id) do
    case Clients.resolve(config, id) do
      {:ok, client} -> {:ok, client}
      {:error, :invalid_client} -> {:error, :unknown_client}
      {:error, reason} -> {:error, :client, reason}
    end
  end

  defp redirect_uri(client, uri) do
    if is_binary(uri) and Redirect.matches?(client.redirect_uris, uri),
      do: :ok,
      else: {:error, :redirect_uri}
  end

  defp validate(config, client, p) do
    known = config |> Config.scopes() |> Enum.map(&elem(&1, 0))
    requested = requested_scopes(p, known)

    with :ok <- check_response_type(p),
         :ok <- check_challenge(p),
         :ok <- check_grant_type(client),
         :ok <- check_scopes(requested, known, client),
         {:ok, resource} <- resource(config, p["resource"]) do
      {:ok,
       %{
         client_id: client.id,
         redirect_uri: p["redirect_uri"],
         code_challenge: p["code_challenge"],
         state: p["state"],
         scopes: requested,
         resource: resource
       }}
    else
      :error ->
        {:error, "invalid_target", "The resource is not served by this authorization server"}

      error ->
        error
    end
  end

  defp requested_scopes(p, known) do
    if is_binary(p["scope"]) and p["scope"] != "", do: String.split(p["scope"]), else: known
  end

  defp check_response_type(%{"response_type" => "code"}), do: :ok

  defp check_response_type(_p),
    do: {:error, "unsupported_response_type", "Only response_type=code is supported"}

  defp check_challenge(p) do
    cond do
      not is_binary(p["code_challenge"]) or p["code_challenge"] == "" ->
        {:error, "invalid_request", "code_challenge is required"}

      p["code_challenge_method"] != "S256" ->
        {:error, "invalid_request", "code_challenge_method must be S256"}

      true ->
        :ok
    end
  end

  defp check_grant_type(client) do
    if "authorization_code" in client.grant_types,
      do: :ok,
      else: {:error, "unauthorized_client", "The client may not use the authorization code grant"}
  end

  defp check_scopes(requested, known, client) do
    cond do
      requested -- known != [] ->
        {:error, "invalid_scope", "Unknown scope: #{Enum.join(requested -- known, " ")}"}

      client.scopes && requested -- client.scopes != [] ->
        {:error, "invalid_scope",
         "The client may not request: #{Enum.join(requested -- client.scopes, " ")}"}

      true ->
        :ok
    end
  end

  @doc false
  def resource(config, nil) do
    case config.resources do
      [pattern] ->
        if String.contains?(pattern, ":"), do: :error, else: {:ok, config.issuer <> pattern}

      _ ->
        :error
    end
  end

  def resource(config, value) when is_binary(value) do
    uri = URI.parse(value)
    path = String.trim_trailing(uri.path || "", "/")

    cond do
      not same_origin?(uri, URI.parse(config.issuer)) -> :error
      config.resources == nil -> {:ok, config.issuer <> path}
      Enum.any?(config.resources, &pattern_match?(&1, path)) -> {:ok, config.issuer <> path}
      true -> :error
    end
  end

  def resource(_config, _), do: :error

  defp same_origin?(uri, issuer) do
    uri.scheme == issuer.scheme and uri.host == issuer.host and uri.port == issuer.port and
      uri.fragment == nil and uri.query == nil
  end

  defp pattern_match?(pattern, path) do
    ps = String.split(pattern, "/", trim: true)
    xs = String.split(path, "/", trim: true)

    length(ps) == length(xs) and
      Enum.zip(ps, xs) |> Enum.all?(fn {p, x} -> String.starts_with?(p, ":") or p == x end)
  end

  defp consent_or_issue(conn, config, client, request, principal) do
    subject_id = config.subject.id(principal)
    {module, state} = Auth.store(config)

    remembered =
      config.remember_consent and
        case module.get_consent(state, subject_id, client.id, request.resource) do
          {:ok, %{scopes: granted}} -> request.scopes -- granted == []
          :error -> false
        end

    if remembered do
      issue_and_redirect(conn, config, request, subject_id)
    else
      blob = Plug.Crypto.sign(secret(), @salt, %{request: request, subject_id: subject_id})
      known = Map.new(Config.scopes(config))
      redirect = URI.parse(request.redirect_uri)

      assigns = %{
        client_name: client.name,
        client_host: client.client_uri && URI.parse(client.client_uri).host,
        redirect_host:
          if(redirect.port && redirect.port not in [80, 443],
            do: "#{redirect.host}:#{redirect.port}",
            else: redirect.host
          ),
        loopback?: Redirect.loopback?(request.redirect_uri),
        subject_display: config.subject.display(principal),
        scopes: Enum.map(request.scopes, &{&1, known[&1]}),
        resource: request.resource,
        request: blob,
        action: conn.request_path,
        csrf_token: csrf_token(),
        issuer_name: config.name
      }

      html(conn, 200, config.consent.render(assigns))
    end
  end

  # ---- POST

  defp decide(conn, config) do
    conn =
      if match?(%Plug.Conn.Unfetched{}, conn.body_params),
        do: Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:urlencoded], pass: ["*/*"])),
        else: conn

    p = conn.body_params

    with {:ok, %{request: request, subject_id: subject_id}} <-
           Plug.Crypto.verify(secret(), @salt, p["request"] || "", max_age: @request_ttl),
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
    maybe_remember(config, request, subject_id)
    issue_and_redirect(conn, config, request, subject_id)
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

  defp maybe_remember(config, request, subject_id) do
    if config.remember_consent do
      {module, state} = Auth.store(config)

      :ok =
        module.put_consent(state, %Sake.Auth.Consent{
          subject_id: subject_id,
          client_id: request.client_id,
          resource: request.resource,
          scopes: request.scopes,
          inserted_at: DateTime.utc_now()
        })
    end
  end

  # ---- codes

  @doc "Issues a code for `request` (a map with client_id, redirect_uri, code_challenge, scopes, resource) and `subject_id`; returns the plain code."
  @spec issue_code(Config.t(), map(), String.t()) :: String.t()
  def issue_code(config, request, subject_id) do
    {module, state} = Auth.store(config)
    code = Tokens.generate()

    :ok =
      module.put_code(state, %Sake.Auth.Code{
        hash: Tokens.hash(code),
        client_id: request.client_id,
        redirect_uri: request.redirect_uri,
        code_challenge: request.code_challenge,
        scopes: request.scopes,
        resource: request.resource,
        subject_id: subject_id,
        expires_at: DateTime.add(DateTime.utc_now(), @code_ttl)
      })

    code
  end

  defp issue_and_redirect(conn, config, request, subject_id) do
    code = issue_code(config, request, subject_id)

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

  defp error_page(conn, config, status, title, message) do
    html(
      conn,
      status,
      config.consent.render_error(%{title: title, message: message, status: status})
    )
  end

  defp html(conn, status, body) do
    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_header("content-security-policy", "frame-ancestors 'none'")
    |> send_resp(status, body)
  end

  # `Plug.CSRFProtection` loads its state into the process dictionary when
  # it runs; only then does a token exist that its own check accepts.
  # Without it the field stays empty and the signed request blob is the
  # defence.
  defp csrf_token do
    if Process.get(:plug_csrf_token_per_host) != nil,
      do: Plug.CSRFProtection.get_csrf_token(),
      else: ""
  end

  defp secret, do: Sake.Secret.fetch!()
end
