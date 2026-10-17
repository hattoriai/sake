defmodule Sake.Auth.Grant do
  @moduledoc false
  # The decision on a validated authorization request once the person is
  # known: refused, issued at once (a remembered consent covers it), or
  # put to the person on the consent page. Then, on their approval, the
  # code, and the consent remembered.
  #
  # Core: it takes the configuration, the request and the principal, and
  # never sees the conn. The authorize endpoint reads the principal and
  # renders the answer; the device flow (`Sake.Auth.Device`) takes the
  # same decision and remembers the consent the same way, and records
  # the approval on its grant in place of a code.

  alias Sake.Auth
  alias Sake.Auth.{AuthorizationRequest, Client, Config, Redirect, Subject, Tokens}

  @code_ttl 600

  @doc """
  What to do with `request` from `client` for `principal`:

    * `{:issue, request}` — a remembered consent covers it: issue a code
      for the request (`issue/3`), whose scopes are narrowed to those the
      person may hold.
    * `{:consent, assigns}` — ask the person: the assigns of
      `c:Sake.Auth.Consent.render/1` that are the request's, with
      `request` the narrowed request itself (the caller signs it into the
      form) and without `action` and `csrf_token`, which are the form's.
    * `{:error, code, description}` — refused, for the redirect URI.

  The scopes are narrowed to those the person may hold
  (`c:Sake.Auth.Subject.scopes_for/2`): the consent page shows those, and
  the code carries them. Nothing left of a request for some is refused.

  A device request is always put to the person, remembered consent or
  not: nothing ties it to the client's redirect URI, so whoever started
  it may have sent someone else the code to approve (RFC 8628 §5.4), and
  only the page, which shows the code, gives them the chance to notice.
  """
  @spec decide(Config.t(), Client.t(), AuthorizationRequest.t(), term()) ::
          {:issue, AuthorizationRequest.t()}
          | {:consent, map()}
          | {:error, String.t(), String.t()}
  def decide(config, client, request, principal) do
    with :ok <- resource_allowed(config, principal, request),
         {:ok, request} <- permitted(config, principal, request) do
      consent_or_issue(config, client, request, principal)
    end
  end

  defp resource_allowed(config, principal, request) do
    if Subject.authorize_resource?(config.subject, principal, request.resource),
      do: :ok,
      else: {:error, "access_denied", "You may not authorize this resource"}
  end

  defp permitted(config, principal, request) do
    scopes = Subject.permitted_scopes(config.subject, principal, request.resource, request.scopes)

    if scopes == [] and request.scopes != [],
      do: {:error, "access_denied", "You may not hold any of the requested scopes"},
      else: {:ok, %{request | scopes: scopes}}
  end

  defp consent_or_issue(config, client, request, principal) do
    if AuthorizationRequest.flow(request) == :authorization_code and
         remembered?(config, client, request, config.subject.id(principal)),
       do: {:issue, request},
       else: {:consent, assigns(config, client, request, principal)}
  end

  defp remembered?(config, client, request, subject_id) do
    {module, state} = Auth.store(config)

    config.remember_consent and
      case module.get_consent(state, subject_id, client.id, request.resource) do
        {:ok, %{scopes: granted}} -> request.scopes -- granted == []
        :error -> false
      end
  end

  defp assigns(config, client, request, principal) do
    known = Map.new(Config.scopes(config))

    Map.merge(redirect(request), %{
      flow: AuthorizationRequest.flow(request),
      user_code: nil,
      client_name: client.name,
      client_host: client.client_uri && URI.parse(client.client_uri).host,
      subject_display: config.subject.display(principal),
      scopes: Enum.map(request.scopes, &{&1, known[&1]}),
      resource: request.resource,
      request: request,
      issuer_name: config.name
    })
  end

  # Where the code goes; a device request sends it nowhere.
  defp redirect(%{redirect_uri: nil}), do: %{redirect_host: nil, loopback?: nil}

  defp redirect(request) do
    redirect = URI.parse(request.redirect_uri)

    %{
      redirect_host:
        if(redirect.port && redirect.port not in [80, 443],
          do: "#{redirect.host}:#{redirect.port}",
          else: redirect.host
        ),
      loopback?: Redirect.loopback?(request.redirect_uri)
    }
  end

  @doc """
  The person approved `request`: remembers the consent (with
  `remember_consent`) and issues the code.
  """
  @spec approve(Config.t(), AuthorizationRequest.t(), String.t()) :: {:ok, String.t()}
  def approve(config, request, subject_id) do
    remember(config, request, subject_id)
    issue(config, request, subject_id)
  end

  @doc "Remembers the consent to `request` (with `remember_consent`), without issuing anything."
  @spec remember(Config.t(), AuthorizationRequest.t(), String.t()) :: :ok
  def remember(config, request, subject_id) do
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

    :ok
  end

  @doc "Issues a code for `request` and `subject_id`, without asking: a remembered consent covers it."
  @spec issue(Config.t(), AuthorizationRequest.t(), String.t()) :: {:ok, String.t()}
  def issue(config, request, subject_id), do: {:ok, issue_code(config, request, subject_id)}

  @doc """
  Issues a code for `request` (a map with client_id, redirect_uri,
  code_challenge, scopes, resource) and `subject_id`; returns the plain
  code.
  """
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
end
