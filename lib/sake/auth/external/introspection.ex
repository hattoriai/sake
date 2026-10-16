defmodule Sake.Auth.External.Introspection do
  @moduledoc false
  # Token introspection (RFC 7662): the resource asks the authorization
  # server whether a token is active, authenticated with its own client
  # credentials, and gets the token's claims back.
  #
  # An active answer is cached for a short while, so that every request
  # of a session is not a round trip: the cache is keyed by a digest of
  # the token (the token itself is never kept), and an entry lasts at
  # most `cache:` seconds and never past the token's `exp`. That is the
  # trade-off with revocation: a token revoked at the authorization
  # server keeps working here until its entry expires. An inactive
  # answer is not cached, so a token that is refused is asked about
  # again (and costs a round trip each time: rate limit the endpoint).

  alias Sake.Auth.External
  alias Sake.Auth.External.Cache

  @timeout 5_000
  @default_cache 60

  @doc "The `{:introspection, opts}` options, checked at start."
  @spec options(External.t(), term(), String.t()) :: map()
  def options(config, opts, label) do
    unless Keyword.keyword?(opts) and
             Keyword.keys(opts) -- [:endpoint, :client_id, :client_secret, :auth_method, :cache] ==
               [],
           do:
             raise(
               ArgumentError,
               "#{label} {:introspection, opts} takes endpoint:, client_id:, client_secret:, auth_method: and cache:"
             )

    External.url!(config, opts[:endpoint], "#{label} introspection endpoint:")

    unless is_binary(opts[:client_id]) and is_binary(opts[:client_secret]),
      do:
        raise(
          ArgumentError,
          "#{label} introspection needs the resource's client_id: and client_secret:"
        )

    method = Keyword.get(opts, :auth_method, :basic)
    cache = Keyword.get(opts, :cache, @default_cache)

    unless method in [:basic, :post],
      do: raise(ArgumentError, "#{label} introspection auth_method: is :basic or :post")

    unless is_integer(cache) and cache >= 0,
      do: raise(ArgumentError, "#{label} introspection cache: is a number of seconds")

    %{
      endpoint: opts[:endpoint],
      client_id: opts[:client_id],
      client_secret: opts[:client_secret],
      auth_method: method,
      cache: cache
    }
  end

  @doc "The claims of an active token, from the cache or the authorization server."
  @spec introspect(External.t(), map(), String.t()) :: {:ok, map()} | {:error, atom()}
  def introspect(config, opts, token) do
    key = {config.name, digest(token)}
    now = System.system_time(:second)

    case Cache.get(key, now) do
      {:ok, claims} ->
        {:ok, claims}

      :error ->
        with {:ok, claims} <- request(opts, token),
             :ok <- active(claims, now),
             do: cache(key, claims, ttl(claims, opts.cache, now), now)
    end
  end

  defp cache(key, claims, ttl, now) do
    if ttl > 0, do: Cache.put(key, claims, now + ttl)
    {:ok, claims}
  end

  defp digest(token), do: :crypto.hash(:sha256, token)

  # RFC 7662 §2.2: `active` is the answer; `exp` and `nbf`, when the
  # server sends them, are checked here too.
  defp active(%{"active" => true} = claims, now) do
    cond do
      External.expired?(claims, now) -> {:error, :expired}
      is_number(claims["nbf"]) and claims["nbf"] > now -> {:error, :not_yet_valid}
      true -> :ok
    end
  end

  defp active(_claims, _now), do: {:error, :inactive}

  defp ttl(%{"exp" => exp}, cache, now) when is_number(exp), do: min(cache, trunc(exp) - now)
  defp ttl(_claims, cache, _now), do: cache

  # RFC 7662 §2.1: a form POST with the token and a hint, authenticated
  # as the resource. RFC 6749 §2.3.1: the id and secret are form-encoded
  # before they are joined for HTTP Basic.
  defp request(opts, token) do
    {form, headers} = authenticate(opts, token: token, token_type_hint: "access_token")

    case Req.post(opts.endpoint,
           form: form,
           headers: [{"accept", "application/json"} | headers],
           redirect: false,
           retry: false,
           decode_body: false,
           receive_timeout: @timeout,
           connect_options: [timeout: @timeout]
         ) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        case JSON.decode(body) do
          {:ok, %{} = claims} -> {:ok, claims}
          _ -> {:error, :invalid_introspection}
        end

      {:ok, %Req.Response{}} ->
        {:error, :introspection_refused}

      {:error, _reason} ->
        {:error, :unreachable}
    end
  end

  defp authenticate(%{auth_method: :post} = opts, form),
    do: {form ++ [client_id: opts.client_id, client_secret: opts.client_secret], []}

  defp authenticate(opts, form) do
    credentials =
      URI.encode_www_form(opts.client_id) <> ":" <> URI.encode_www_form(opts.client_secret)

    {form, [{"authorization", "Basic " <> Base.encode64(credentials)}]}
  end
end

defmodule Sake.Auth.External.Cache do
  @moduledoc false
  # The introspection answers, in an ETS table with an expiry per entry.
  # It is bounded: when it is full, the expired entries go, and when it
  # is still full nothing new is cached, so a flood of tokens costs
  # round trips to the authorization server, never memory.
  use GenServer

  @table __MODULE__
  @max_entries 10_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def child_spec(_), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [nil]}}

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  @doc false
  def max_entries, do: @max_entries

  @spec get(term(), integer()) :: {:ok, map()} | :error
  def get(key, now) do
    case :ets.whereis(@table) != :undefined and :ets.lookup(@table, key) do
      [{^key, claims, expires_at}] when now < expires_at -> {:ok, claims}
      _ -> :error
    end
  end

  @spec put(term(), map(), integer()) :: :ok
  def put(key, claims, expires_at) do
    if :ets.whereis(@table) != :undefined do
      now = System.system_time(:second)

      if :ets.info(@table, :size) >= @max_entries,
        do: :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])

      if :ets.info(@table, :size) < @max_entries,
        do: :ets.insert(@table, {key, claims, expires_at})
    end

    :ok
  end
end
