defmodule Sake.Auth.Device do
  @moduledoc false
  # The device authorization grant (RFC 8628), for a client with no
  # browser: it asks the device authorization endpoint for a device code
  # and a user code, shows the person the user code and where to enter
  # it, and polls the token endpoint with the device code while the
  # person signs in elsewhere and decides.
  #
  # The request is validated as an authorization request
  # (`AuthorizationRequest.validate/4` with `:device`), and the person's
  # decision goes through `Grant.decide/4`, so `authorize_resource?/2`,
  # `scopes_for/2` and the consent page apply as in the code flow, and
  # so do `acr_values` and `max_age` (RFC 9470), kept in the grant's
  # `extra` and checked before the decision. An approval is recorded on
  # the device grant, with how the person signed in, which the token
  # endpoint's device code clause (`Sake.Auth.TokenGrants`) turns into
  # tokens once.
  #
  # Both codes are stored hashed: the device code as codes and tokens
  # are, the user code with an HMAC keyed by the Sake secret, since its
  # few bits would not stand up to a search through every possible code.
  # A signed-in person gets five entries of a user code a minute, which
  # is what makes those few bits enough.
  #
  # Core: it takes the configuration, the parameters, the user code and
  # the principal, and never sees the conn; `Sake.Auth.DeviceAuthorization`
  # and `Sake.Auth.DeviceVerification` are the adapters.

  alias Sake.Auth

  alias Sake.Auth.{
    Authentication,
    AuthorizationRequest,
    ClientAuth,
    Clients,
    Config,
    DeviceGrant,
    Grant,
    Tokens
  }

  # RFC 8628 §6.1: base 20, with no vowels (so no words) and none of the
  # letters and digits that look alike; 8 characters, about 34.5 bits.
  @alphabet ~c"BCDFGHJKLMNPQRSTVWXZ"
  @user_code_length 8

  # Entries of a user code each signed-in person may make in a window.
  @guesses 5
  @guess_window 60

  @doc """
  A device authorization request (RFC 8628 §3.1): authenticates the
  client as the token endpoint does, then `start/3`. Returns the
  response, or the HTTP status, error code and description.
  """
  @spec authorize(Config.t(), map(), ClientAuth.credentials()) ::
          {:ok, map()} | {:error, 400 | 401, String.t(), String.t()}
  def authorize(config, p, credentials) do
    case ClientAuth.authenticate(config, credentials, p) do
      {:ok, client} ->
        case start(config, client, p) do
          {:ok, response} -> {:ok, response}
          {:error, code, description} -> {:error, 400, code, description}
        end

      {:error, :invalid_client} ->
        {:error, 401, "invalid_client", "Client authentication failed"}
    end
  end

  @doc """
  Starts a device grant for an authenticated `client`: validates the
  scopes and the resource, stores the grant and returns the device
  authorization response (RFC 8628 §3.2).
  """
  @spec start(Config.t(), Sake.Auth.Client.t(), map()) ::
          {:ok, map()} | {:error, String.t(), String.t()}
  def start(config, client, p) do
    with {:ok, request} <- AuthorizationRequest.validate(config, client, p, :device) do
      {module, state} = Auth.store(config)
      device_code = Tokens.generate()
      user_code = user_code()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      :ok =
        module.put_device_grant(state, %DeviceGrant{
          hash: Tokens.hash(device_code),
          user_code_hash: user_code_hash(config, user_code),
          client_id: client.id,
          scopes: request.scopes,
          resource: request.resource,
          extra: request.extra,
          interval: config.device.interval,
          expires_at: DateTime.add(now, config.device.expires_in),
          inserted_at: now
        })

      shown = format(user_code)

      {:ok,
       %{
         "device_code" => device_code,
         "user_code" => shown,
         "verification_uri" => Config.device_url(config),
         "verification_uri_complete" =>
           Config.device_url(config) <> "?" <> URI.encode_query(%{"user_code" => shown}),
         "expires_in" => config.device.expires_in,
         "interval" => config.device.interval
       }}
    end
  end

  @doc """
  Counts an entry of a user code by `subject_id`: `:ok`, or `:limited`
  once the person has made `#{@guesses}` in the current minute. The
  verification page calls it before every lookup.
  """
  @spec attempt(Config.t(), String.t()) :: :ok | :limited
  def attempt(config, subject_id) do
    {module, state} = Auth.store(config)
    window = div(System.system_time(:second), @guess_window)
    expires_at = (window + 1) * @guess_window
    free? = &(module.once(state, guess_key(subject_id, window, &1), expires_at) == :ok)

    if Enum.any?(1..@guesses, free?), do: :ok, else: :limited
  end

  # One key for each of the window's entries, the first free one taken.
  defp guess_key(subject_id, window, n) do
    :sha256
    |> :crypto.hash(["sake.device.guess", 0, subject_id, 0, "#{window}:#{n}"])
    |> Base.url_encode64(padding: false)
  end

  @doc """
  The pending, unexpired device grant a user code names, with its
  client and the authorization request it stands for. `:error` for
  anything else, whatever the reason: the page says no more than that
  the code is not valid.
  """
  @spec lookup(Config.t(), term()) ::
          {:ok,
           %{
             grant: DeviceGrant.t(),
             client: Sake.Auth.Client.t(),
             request: AuthorizationRequest.t()
           }}
          | :error
  def lookup(config, user_code) do
    {module, state} = Auth.store(config)

    with {:ok, code} <- normalize(user_code),
         {:ok, %DeviceGrant{status: :pending} = grant} <-
           module.get_device_grant_by_user_code(state, user_code_hash(config, code)),
         true <- DateTime.compare(grant.expires_at, DateTime.utc_now()) == :gt,
         {:ok, client} <- Clients.resolve(config, grant.client_id) do
      {:ok,
       %{
         grant: grant,
         client: client,
         request: %AuthorizationRequest{
           client_id: grant.client_id,
           scopes: grant.scopes,
           resource: grant.resource,
           extra: grant.extra || %{}
         }
       }}
    else
      _ -> :error
    end
  end

  @doc """
  What to show `principal` for a user code: `{:consent, assigns}`, the
  consent page's assigns from `Grant.decide/4`, with the `user_code` to
  compare with the device's; `:error` for a code that is not valid; or
  `{:error, code, description}` when the person may not authorize the
  request, which denies the grant, so the device stops polling.

  `authentication` is how the person signed in: a request whose
  `acr_values` or `max_age` (RFC 9470) it does not meet is
  `{:reauthenticate, requirement}`, before anything is decided, and the
  grant stays pending for when they come back.
  """
  @spec prompt(Config.t(), term(), term(), Authentication.context()) ::
          {:consent, map()}
          | {:reauthenticate, Authentication.requirement()}
          | :error
          | {:error, String.t(), String.t()}
  def prompt(config, user_code, principal, authentication \\ Authentication.none()) do
    with {:ok, found} <- lookup(config, user_code),
         :ok <- authenticated(found.request, authentication) do
      case Grant.decide(config, found.client, found.request, principal) do
        {:consent, assigns} ->
          {:consent, Map.put(assigns, :user_code, shown(user_code))}

        {:error, code, description} ->
          deny(config, found.grant)
          {:error, code, description}
      end
    end
  end

  defp authenticated(request, authentication) do
    requirement = Authentication.requested(request.extra)

    case Authentication.check(authentication, requirement) do
      :ok -> :ok
      {:error, _reason} -> {:reauthenticate, requirement}
    end
  end

  @doc """
  The person's decision on the grant a user code names. An approval
  takes `Grant.decide/4` again, with the scopes narrowed as they are
  now, records it on the grant, with how the person signed in
  (`authentication`, which the tokens carry), and remembers the consent
  (with `remember_consent`). `:error` when the code is not valid any
  more (it expired, or the grant was decided meanwhile: the decision is
  atomic).
  """
  @spec decide(Config.t(), term(), term(), :approve | :deny, Authentication.context()) ::
          :ok | :error | {:error, String.t(), String.t()}
  def decide(config, user_code, principal, decision, authentication \\ Authentication.none())

  def decide(config, user_code, principal, :approve, authentication) do
    with {:ok, found} <- lookup(config, user_code) do
      case Grant.decide(config, found.client, found.request, principal) do
        {:consent, %{request: request}} ->
          approve(config, found.grant, request, config.subject.id(principal), authentication)

        {:error, code, description} ->
          deny(config, found.grant)
          {:error, code, description}
      end
    end
  end

  def decide(config, user_code, _principal, :deny, _authentication) do
    with {:ok, found} <- lookup(config, user_code), do: deny(config, found.grant)
  end

  defp approve(config, grant, request, subject_id, authentication) do
    {module, state} = Auth.store(config)
    decision = {:approved, subject_id, request.scopes, Authentication.context(authentication)}

    with :ok <- module.decide_device_grant(state, grant.hash, decision),
         do: Grant.remember(config, request, subject_id)
  end

  defp deny(config, grant) do
    {module, state} = Auth.store(config)
    module.decide_device_grant(state, grant.hash, :denied)
  end

  # ---- user codes

  # Random bytes, each kept only below the largest multiple of the
  # alphabet's size, so every character is as likely as the others.
  defp user_code, do: user_code("")

  defp user_code(code) when byte_size(code) == @user_code_length, do: code

  defp user_code(code) do
    size = length(@alphabet)
    limit = div(256, size) * size

    code =
      for <<byte <- :crypto.strong_rand_bytes(@user_code_length)>>,
          byte < limit,
          into: code,
          do: <<Enum.at(@alphabet, rem(byte, size))>>

    user_code(binary_part(code, 0, min(byte_size(code), @user_code_length)))
  end

  @doc """
  A user code as the person may have typed it, normalized (RFC 8628
  §6.1): neither case nor anything but letters and digits (the dash,
  spaces) counts.
  """
  @spec normalize(term()) :: {:ok, String.t()} | :error
  def normalize(user_code) when is_binary(user_code) do
    code = for <<c <- String.upcase(user_code)>>, c in ?A..?Z or c in ?0..?9, into: "", do: <<c>>

    if byte_size(code) == @user_code_length and
         Enum.all?(String.to_charlist(code), &(&1 in @alphabet)),
       do: {:ok, code},
       else: :error
  end

  def normalize(_user_code), do: :error

  # The code as the device shows it: two groups of four.
  defp format(<<a::binary-size(4), b::binary-size(4)>>), do: a <> "-" <> b

  defp shown(user_code) do
    {:ok, code} = normalize(user_code)
    format(code)
  end

  @doc false
  # The user code's digest, as stored.
  @spec user_code_hash(Config.t(), String.t()) :: String.t()
  def user_code_hash(%Config{secret: secret}, code) when is_binary(secret),
    do:
      :hmac
      |> :crypto.mac(:sha256, secret, "sake.device.user_code:" <> code)
      |> Base.encode16(case: :lower)
end
