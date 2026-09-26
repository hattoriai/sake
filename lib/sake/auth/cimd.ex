defmodule Sake.Auth.CIMD do
  @moduledoc """
  Client ID Metadata Documents: a client identifies itself with an HTTPS
  URL, and the authorization server fetches the JSON document there.

  The fetch is guarded: HTTPS only (unless `allow_insecure`), the host
  must resolve to public addresses, no redirects are followed, the body is
  limited to 64 KB, and the request times out after 5 seconds. Documents
  are cached for their `max-age`, clamped to one minute–one day.
  """

  alias Sake.Auth.{Client, Config, Redirect}

  @max_body 65_536
  @timeout 5_000

  @spec url?(term()) :: boolean()
  def url?(id) when is_binary(id) do
    match?(
      %URI{scheme: "https", host: h, path: p, fragment: nil}
      when is_binary(h) and is_binary(p) and p != "/" and p != "",
      URI.parse(id)
    )
  end

  def url?(_), do: false

  defp url?(id, %Config{allow_insecure: true}) when is_binary(id) do
    url?(id) or
      match?(
        %URI{scheme: "http", host: h, path: p}
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
        addrs = resolve(host, :inet) ++ resolve(host, :inet6)
        addrs != [] and Enum.all?(addrs, &public_ip?/1)
    end
  end

  defp resolve(host, family) do
    case :inet.getaddrs(String.to_charlist(host), family) do
      {:ok, addrs} -> addrs
      {:error, _} -> []
    end
  end

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

  defp public_ip?({0, 0, 0, 0, 0, 0xFFFF, a, b}),
    do: public_ip?({div(a, 256), rem(a, 256), div(b, 256), rem(b, 256)})

  defp public_ip?({a, _, _, _, _, _, _, _}) when a in 0xFC00..0xFDFF, do: false
  defp public_ip?({a, _, _, _, _, _, _, _}) when a in 0xFE80..0xFEBF, do: false
  defp public_ip?(_), do: true

  defp download(uri) do
    request =
      Req.new(
        url: URI.to_string(uri),
        headers: [{"accept", "application/json"}],
        redirect: false,
        retry: false,
        receive_timeout: @timeout,
        connect_options: [timeout: @timeout],
        decode_body: false,
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
         true <- Enum.all?(uris, &Redirect.valid?/1),
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
      [{^key, value, expires_at}] ->
        if System.system_time(:second) < expires_at, do: {:ok, value}, else: :error

      [] ->
        :error
    end
  end

  def put(key, value, ttl) do
    :ets.insert(@table, {key, value, System.system_time(:second) + ttl})
    :ok
  end
end
