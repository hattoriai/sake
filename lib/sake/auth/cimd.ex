defmodule Sake.Auth.CIMD do
  @moduledoc """
  Client ID Metadata Documents: a client identifies itself with an HTTPS
  URL, and the authorization server fetches the JSON document there.

  The fetch is guarded: HTTPS only (unless `allow_insecure`), no
  credentials in the URL, the host must resolve to public addresses, no
  redirects are followed, the body is limited to 64 KB, and the whole
  download must finish within 5 seconds. A document may list at most 10
  redirect URIs. Documents are cached for their `max-age`, clamped to one
  minute–one day; the cache holds at most 1000 documents.
  """

  alias Sake.Auth.{Client, Config, Redirect}

  @max_body 65_536
  @timeout 5_000
  @max_redirect_uris 10

  @spec url?(term()) :: boolean()
  def url?(id) when is_binary(id) do
    match?(
      %URI{scheme: "https", host: h, path: p, fragment: nil, userinfo: nil}
      when is_binary(h) and is_binary(p) and p != "/" and p != "",
      URI.parse(id)
    )
  end

  def url?(_), do: false

  defp url?(id, %Config{allow_insecure: true}) when is_binary(id) do
    url?(id) or
      match?(
        %URI{scheme: "http", host: h, path: p, userinfo: nil}
        when is_binary(h) and is_binary(p) and p not in ["", "/"],
        URI.parse(id)
      )
  end

  defp url?(id, _config), do: url?(id)

  @spec fetch(Config.t(), term()) ::
          {:ok, Client.t()}
          | {:error, :invalid_client | :not_allowed | :unreachable | :invalid_document}
  def fetch(%Config{cimd: false}, _id), do: {:error, :not_allowed}

  def fetch(config, id) do
    uri = URI.parse(to_string(id))

    cond do
      not url?(id, config) -> {:error, :invalid_client}
      not allowed?(config, uri) -> {:error, :not_allowed}
      not config.allow_insecure and not public_host?(uri.host) -> {:error, :not_allowed}
      true -> cached(id, uri)
    end
  end

  defp cached(id, uri) do
    case __MODULE__.Cache.get({:cimd, id}) do
      {:ok, client} ->
        {:ok, client}

      :error ->
        with {:ok, body, ttl} <- download(uri),
             {:ok, client} <- parse(id, body) do
          __MODULE__.Cache.put({:cimd, id}, client, ttl)
          {:ok, client}
        end
    end
  end

  defp allowed?(%Config{cimd: opts}, uri) do
    case Keyword.get(opts, :policy, :allow_all) do
      :allow_all -> true
      {:allow, hosts} -> uri.host in hosts
      {module, fun} -> apply(module, fun, [uri])
    end
  end

  @doc "Whether the host resolves only to public unicast addresses."
  @spec public_host?(String.t()) :: boolean()
  def public_host?(host) do
    case :inet.parse_address(String.to_charlist(String.trim(host, "[]"))) do
      {:ok, ip} ->
        public_ip?(ip)

      {:error, _} ->
        case resolve_all(host) do
          :timeout -> false
          addrs -> addrs != [] and Enum.all?(addrs, &public_ip?/1)
        end
    end
  end

  # Bounded to `@timeout`, same as the HTTP fetch: an unresponsive DNS
  # server must not be able to hang the fetch indefinitely.
  defp resolve_all(host) do
    task = Task.async(fn -> resolve(host, :inet) ++ resolve(host, :inet6) end)

    case Task.yield(task, @timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, addrs} -> addrs
      _ -> :timeout
    end
  end

  defp resolve(host, family) do
    case :inet.getaddrs(String.to_charlist(host), family) do
      {:ok, addrs} -> addrs
      {:error, _} -> []
    end
  end

  defp public_ip?({a, _, _, _}) when a >= 224, do: false
  defp public_ip?({198, b, _, _}) when b in 18..19, do: false
  defp public_ip?({10, _, _, _}), do: false
  defp public_ip?({127, _, _, _}), do: false
  defp public_ip?({169, 254, _, _}), do: false
  defp public_ip?({172, b, _, _}) when b in 16..31, do: false
  defp public_ip?({192, 168, _, _}), do: false
  defp public_ip?({0, _, _, _}), do: false
  defp public_ip?({100, b, _, _}) when b in 64..127, do: false
  defp public_ip?({_, _, _, _}), do: true
  defp public_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: false
  defp public_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: false

  # IPv4-mapped (::ffff:a.b.c.d) and IPv4-compatible (::a.b.c.d)
  # addresses, NAT64 (64:ff9b::/96) and 6to4 (2002::/16) all reach an
  # IPv4 address a guard on IPv4 alone would not see; they are refused.
  defp public_ip?({0, 0, 0, 0, 0, 0xFFFF, _, _}), do: false
  defp public_ip?({0, 0, 0, 0, 0, 0, _, _}), do: false
  defp public_ip?({0x64, 0xFF9B, 0, 0, 0, 0, _, _}), do: false
  defp public_ip?({0x2002, _, _, _, _, _, _, _}), do: false

  defp public_ip?({a, _, _, _, _, _, _, _}) when a in 0xFC00..0xFDFF, do: false
  defp public_ip?({a, _, _, _, _, _, _, _}) when a in 0xFE80..0xFEBF, do: false
  defp public_ip?(_), do: true

  # The whole download runs under one deadline: Req's own timeouts bound
  # the connect and each receive, not a server that trickles bytes.
  # `Sake.Auth.JWKS` fetches key sets through it too.
  @doc false
  @spec download(URI.t()) :: {:ok, binary(), pos_integer()} | {:error, :unreachable}
  def download(uri) do
    task = Task.async(fn -> download_now(uri) end)

    case Task.yield(task, @timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, :unreachable}
    end
  end

  defp download_now(uri) do
    request =
      Req.new(
        url: URI.to_string(uri),
        headers: [{"accept", "application/json"}],
        redirect: false,
        retry: false,
        receive_timeout: @timeout,
        connect_options: [timeout: @timeout],
        # Never negotiate or apply compression: `compressed: false` sends no
        # `accept-encoding` header, and `raw: true` disables both the
        # `decompress_body` and `decode_body` steps, so a server-supplied
        # `content-encoding` is never inflated and the 64 KB cap below is
        # always a cap on the real (decompressed) bytes we hold.
        compressed: false,
        raw: true,
        into: fn {:data, data}, {req, resp} ->
          body = (resp.body || "") <> data

          if byte_size(body) > @max_body,
            do: {:halt, {req, %{resp | body: :too_large}}},
            else: {:cont, {req, %{resp | body: body}}}
        end
      )

    case Req.get(request) do
      {:ok, %Req.Response{status: 200, body: body, headers: headers}} when is_binary(body) ->
        {:ok, body, ttl(headers)}

      _ ->
        {:error, :unreachable}
    end
  rescue
    _ -> {:error, :unreachable}
  end

  defp ttl(headers) do
    with [value | _] <- Map.get(headers, "cache-control", []),
         [_, seconds] <- Regex.run(~r/max-age=(\d+)/, value) do
      seconds |> String.to_integer() |> min(86_400) |> max(60)
    else
      _ -> 3_600
    end
  end

  defp parse(id, body) do
    with {:ok,
          %{"client_id" => ^id, "client_name" => name, "redirect_uris" => [_ | _] = uris} = doc} <-
           JSON.decode(body),
         true <- is_binary(name) and String.length(name) in 1..100,
         true <- length(uris) <= @max_redirect_uris,
         true <- Enum.all?(uris, &Redirect.valid?/1),
         true <- Sake.Auth.Clients.metadata_types_valid?(doc),
         method = doc["token_endpoint_auth_method"] || "none",
         true <- method == "none" do
      {:ok,
       %Client{
         id: id,
         name: name,
         kind: :cimd,
         redirect_uris: uris,
         grant_types: doc["grant_types"] || ["authorization_code", "refresh_token"],
         token_endpoint_auth_method: "none",
         client_uri: doc["client_uri"],
         logo_uri: doc["logo_uri"],
         scopes: if(is_binary(doc["scope"]), do: String.split(doc["scope"]), else: nil),
         application_type: doc["application_type"] || "native"
       }}
    else
      _ -> {:error, :invalid_document}
    end
  end
end

defmodule Sake.Auth.CIMD.Cache do
  @moduledoc false
  # An ETS-backed cache with per-entry expiry, keyed by whatever the caller
  # chooses.
  use GenServer
  @table __MODULE__
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def child_spec(_), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [nil]}}

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, value, expires_at, _inserted}] ->
        if System.system_time(:second) < expires_at, do: {:ok, value}, else: :error

      [] ->
        :error
    end
  end

  @max_entries 1_000

  @doc false
  def max_entries, do: @max_entries

  # Bounded: when full, expired entries go first, then, if the cache is
  # still full, the oldest entry.
  def put(key, value, ttl) do
    now = System.system_time(:second)

    if :ets.info(@table, :size) >= @max_entries and not :ets.member(@table, key) do
      :ets.select_delete(@table, [{{:_, :_, :"$1", :_}, [{:"=<", :"$1", now}], [true]}])
      evict_oldest()
    end

    :ets.insert(@table, {key, value, now + ttl, System.unique_integer([:monotonic])})
    :ok
  end

  defp evict_oldest do
    if :ets.info(@table, :size) >= @max_entries do
      {key, _} = :ets.foldl(&older/2, nil, @table)
      :ets.delete(@table, key)
    end
  end

  defp older({k, _, _, at}, nil), do: {k, at}
  defp older({k, _, _, at}, {_, oldest}) when at < oldest, do: {k, at}
  defp older(_entry, acc), do: acc
end
