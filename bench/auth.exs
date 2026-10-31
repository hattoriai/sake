# What authorization costs per call: the same `tools/call` with no token,
# Sake's own tokens (bearer, and DPoP-bound with a proof checked on every
# request), and tokens of an authorization server Sake does not run
# (`Sake.Auth.External`: a JWT, introspection, a callback).
#
#     mix run bench/auth.exs
#     DATABASE_URL=ecto://postgres:postgres@localhost/sake_bench mix run bench/auth.exs
#
# With `DATABASE_URL`, Sake's own tokens are measured a second time with
# the Ecto store (`Sake.Auth.Store.Ecto`, Postgres), as an app that keeps
# tokens across restarts runs them.
#
# See guides/performance.md for how to read the numbers.

Code.require_file("support.exs", __DIR__)

alias Sake.Auth.{DPoP, JWT}

defmodule Bench.Subject do
  @behaviour Sake.Auth.Subject
  @impl true
  def from_conn(_conn), do: :error
  @impl true
  def id(user), do: user.id
  @impl true
  def fetch(id), do: {:ok, %{id: id}}
  @impl true
  def display(user), do: user.id
end

defmodule Bench.Introspect do
  # An authorization server's introspection endpoint (RFC 7662) that
  # answers every token as active.
  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    {:ok, _body, conn} = read_body(conn)

    answer = %{
      "active" => true,
      "sub" => "u1",
      "client_id" => "app",
      "scope" => "bench",
      "aud" => [
        "http://www.example.com/introspection/mcp",
        "http://www.example.com/introspection-uncached/mcp"
      ],
      "exp" => System.system_time(:second) + 600
    }

    conn |> put_resp_content_type("application/json") |> send_resp(200, JSON.encode!(answer))
  end
end

defmodule Bench.Keys do
  @doc "A new P-256 private key and its public JWK."
  def new do
    pem =
      {:namedCurve, :secp256r1}
      |> :public_key.generate_key()
      |> then(&:public_key.pem_encode([:public_key.pem_entry_encode(:PrivateKeyInfo, &1)]))

    {:ok, key} = JWT.private_key(pem)
    {key, JWT.public_jwk(key)}
  end
end

defmodule Bench.Proofs do
  # DPoP proofs signed before the measurement starts, one per request: a
  # proof is good for one request only, and signing it is the client's
  # cost, not the server's.
  def prepare(key, access, count) do
    proofs =
      1..count
      |> Task.async_stream(
        fn _ -> DPoP.proof(key, "POST", "http://www.example.com/mcp", access_token: access) end,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, proof} -> proof end)
      |> List.to_tuple()

    :persistent_term.put(__MODULE__, {proofs, :atomics.new(1, [])})
  end

  def next do
    {proofs, counter} = :persistent_term.get(__MODULE__)
    i = :atomics.add_get(counter, 1, 1)

    if i > tuple_size(proofs),
      do: raise("ran out of DPoP proofs; raise the count in bench/auth.exs"),
      else: elem(proofs, i - 1)
  end
end

if url = System.get_env("DATABASE_URL") do
  defmodule Bench.Repo do
    use Ecto.Repo, otp_app: :sake, adapter: Ecto.Adapters.Postgres
  end

  defmodule Bench.Migration do
    use Ecto.Migration
    def up, do: Sake.Auth.Migration.up()
    def down, do: Sake.Auth.Migration.down()
  end

  Application.put_env(:sake, Bench.Repo, url: url, pool_size: 20, log: false)
end

quick? = System.get_env("BENCH_QUICK") in ["1", "true"]
proof_count = if quick?, do: 40_000, else: 80_000
resource = "http://www.example.com/mcp"
echo = %{"name" => "echo", "arguments" => %{"text" => "hello"}}

{:ok, intro} = Bandit.start_link(plug: Bench.Introspect, ip: :loopback, port: 0)
{:ok, {_ip, intro_port}} = ThousandIsland.listener_info(intro)
intro_url = "http://127.0.0.1:#{intro_port}/introspect"

{idp_key, idp_jwk} = Bench.Keys.new()

idp_token =
  JWT.sign(
    %{
      "iss" => "https://idp.example.com",
      "sub" => "u1",
      "aud" => "http://www.example.com/jwt/mcp",
      "client_id" => "app",
      "scope" => "bench",
      "iat" => System.system_time(:second),
      "exp" => System.system_time(:second) + 3600
    },
    idp_key,
    JWT.default_alg(idp_key),
    # An access token in the JWT profile (RFC 9068).
    %{"typ" => "at+jwt"}
  )

external = [
  jwt: [
    issuer: "https://idp.example.com",
    verify: :jwt,
    jwks: %{"keys" => [idp_jwk]},
    servers: [Bench.Server],
    resources: ["/jwt/mcp"]
  ],
  introspection: [
    issuer: "http://127.0.0.1:#{intro_port}",
    verify: {:introspection, endpoint: intro_url, client_id: "bench", client_secret: "s3cret"},
    servers: [Bench.Server],
    resources: ["/introspection/mcp"],
    allow_insecure: true
  ],
  introspection_uncached: [
    issuer: "http://127.0.0.1:#{intro_port}",
    verify:
      {:introspection, endpoint: intro_url, client_id: "bench", client_secret: "s3cret", cache: 0},
    servers: [Bench.Server],
    resources: ["/introspection-uncached/mcp"],
    allow_insecure: true
  ],
  callback: [
    issuer: "https://app.example.com",
    verify: fn
      "app-token", _conn ->
        {:ok,
         %{"sub" => "u1", "scope" => "bench", "aud" => "http://www.example.com/callback/mcp"}}

      _token, _conn ->
        :error
    end,
    servers: [Bench.Server],
    resources: ["/callback/mcp"]
  ]
]

start = fn store ->
  {:ok, pid} =
    Supervisor.start_link(
      [
        {Sake,
         secret_key_base: Bench.secret(),
         auth: [
           subject: Bench.Subject,
           issuer: "http://www.example.com",
           allow_insecure: true,
           servers: [Bench.Server],
           resources: ["/mcp"],
           store: store
         ],
         external_auth: external}
      ],
      strategy: :one_for_one
    )

  pid
end

issue = fn attrs ->
  {access, _refresh, _records} =
    Sake.Auth.Tokens.issue_pair(
      Sake.Auth.config(),
      Map.merge(
        %{
          client_id: "bench",
          subject_id: "u1",
          scopes: ["bench"],
          resource: resource,
          family_id: Sake.Auth.Tokens.hash("bench-#{System.unique_integer([:positive])}")
        },
        attrs
      )
    )

  access
end

own_tokens = fn label ->
  {dpop_key, dpop_jwk} = Bench.Keys.new()

  bearer = issue.(%{})
  bound = issue.(%{jkt: JWT.thumbprint(dpop_jwk)})
  Bench.Proofs.prepare(dpop_key, bound, proof_count)
  plug = Bench.plug(Bench.Server, auth: true)

  %{
    "Sake.Auth bearer (#{label})" => fn ->
      Bench.call!(
        Bench.modern_conn("tools/call", echo, [{"authorization", "Bearer " <> bearer}]),
        plug
      )
    end,
    "Sake.Auth DPoP-bound, proof per request (#{label})" => fn ->
      Bench.call!(
        Bench.modern_conn("tools/call", echo, [
          {"authorization", "DPoP " <> bound},
          {"dpop", Bench.Proofs.next()}
        ]),
        plug
      )
    end
  }
end

IO.puts("# Authorization cost\n\n#{Bench.environment()}\n")

sake = start.({Sake.Auth.Store.ETS, []})
open = Bench.plug(Bench.Server)
by_name = fn name -> Bench.plug(Bench.Server, auth: name) end

[jwt, introspection, introspection_uncached, callback] =
  Enum.map([:jwt, :introspection, :introspection_uncached, :callback], by_name)

external_call = fn plug, path, token ->
  fn ->
    Bench.call!(
      Bench.modern_conn("tools/call", echo, [{"authorization", "Bearer " <> token}], path),
      plug
    )
  end
end

scenarios =
  Map.merge(own_tokens.("ETS store"), %{
    "no authorization" => fn -> Bench.call!(Bench.modern_conn("tools/call", echo), open) end,
    "External: JWT (ES256)" => external_call.(jwt, "/jwt/mcp", idp_token),
    "External: introspection, cached" =>
      external_call.(introspection, "/introspection/mcp", "intro-token"),
    "External: introspection, every request (local HTTP)" =>
      external_call.(introspection_uncached, "/introspection-uncached/mcp", "intro-token"),
    "External: callback" => external_call.(callback, "/callback/mcp", "app-token")
  })

# Every scenario is checked once before it is measured.
Bench.check!(scenarios)
Bench.run("auth", scenarios)
Supervisor.stop(sake)

if Code.ensure_loaded?(Bench.Repo) do
  _ = Ecto.Adapters.Postgres.storage_up(Bench.Repo.config())
  {:ok, _} = Bench.Repo.start_link()
  Ecto.Migrator.run(Bench.Repo, [{0, Bench.Migration}], :up, all: true, log: false)

  start.({Sake.Auth.Store.Ecto, repo: Bench.Repo})
  scenarios = own_tokens.("Ecto store, Postgres")
  Bench.check!(scenarios)
  Bench.run("auth", scenarios)
end
