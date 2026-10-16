defmodule SakeTest.Keys do
  @moduledoc false
  # Signing keys for the JWT tests, and a server for documents (key sets,
  # issuer metadata) at chosen paths, which a test may change while it
  # runs.

  alias Sake.Auth.JWT

  @doc "A new private key (`:ec`, `:p384` or `:rsa`) as PEM."
  def pem(kind \\ :ec) do
    spec =
      case kind do
        :ec -> {:namedCurve, :secp256r1}
        :p384 -> {:namedCurve, :secp384r1}
        :rsa -> {:rsa, 2048, 65_537}
      end

    key = :public_key.generate_key(spec)
    :public_key.pem_encode([:public_key.pem_entry_encode(:PrivateKeyInfo, key)])
  end

  @doc "A new private key and its public JWK, with `kid` when given."
  def key(kind \\ :ec, kid \\ nil) do
    {:ok, key} = kind |> pem() |> JWT.private_key()
    jwk = JWT.public_jwk(key)
    {key, if(kid, do: Map.put(jwk, "kid", kid), else: jwk)}
  end

  @doc "Signs `claims` with `key` (its default algorithm unless `alg:`), `header` merged in."
  def sign(claims, key, header \\ %{}) do
    {alg, header} = Map.pop(header, "alg", JWT.default_alg(key))
    JWT.sign(claims, key, alg, header)
  end

  @doc "Seconds since the epoch, `offset` from now."
  def now(offset \\ 0), do: System.system_time(:second) + offset

  @doc "A unique `jti`."
  def jti, do: "jti-" <> Integer.to_string(System.unique_integer([:positive]))

  defmodule Documents do
    @moduledoc false
    @behaviour Plug
    import Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, agent) do
      send(Agent.get(agent, & &1.test), {:document_served, conn.request_path})

      case Agent.get(agent, &Map.get(&1.docs, conn.request_path)) do
        nil ->
          send_resp(conn, 404, "")

        doc ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, JSON.encode!(doc))
      end
    end
  end

  @doc """
  Serves `docs` (path => JSON map) on a random port; returns the base URL
  and the Agent holding them (`put/3` changes one).
  """
  def serve(docs) do
    test = self()
    {:ok, agent} = Agent.start_link(fn -> %{docs: docs, test: test} end)
    {SakeTest.HTTP.start({Documents, agent}), agent}
  end

  def put(agent, path, doc), do: Agent.update(agent, &put_in(&1, [:docs, path], doc))
end
