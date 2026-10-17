# The development server: `mix dev`, then http://localhost:4000.
#
#   claude mcp add --transport http sake-dev http://localhost:4000/acme/mcp
#
# Sign in as ana@example.com / secret when the browser opens.
Logger.configure(level: :info)

secret = String.duplicate("dev-secret-", 6)

# The key ID tokens are signed with (OpenID Connect), new at each start.
signing_key =
  {:rsa, 2048, 65_537}
  |> :public_key.generate_key()
  |> then(&:public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, &1)]))

children = [
  {Sake,
   secret_key_base: secret,
   auth: [
     subject: SakeDev.Subject,
     issuer: "http://localhost:4000",
     allow_insecure: true,
     servers: [SakeDev.Server, SakeDev.Gateway],
     resources: ["/mcp", "/acme/mcp", "/beta/mcp", "/gateway/mcp"],
     # The device grant, for a CLI with no browser: its verification
     # page is /oauth/device.
     device: true,
     # Pushed authorization requests (RFC 9126), at /oauth/par: a client
     # may push its request, and Sake.Client does.
     par: true,
     # OpenID Connect: an ID token for the openid scope, the person's name
     # and address at /oauth/userinfo, the key at /oauth/jwks.
     openid: true,
     signing_keys: [[kid: "dev", pem: signing_key]]
   ]},
  {Bandit, plug: SakeDev.Router, port: 4000},
  # The gateway's proxy, whose upstream is this server's /open/mcp.
  SakeDev.Gateway.Open
]

{:ok, _} = Supervisor.start_link(children, strategy: :one_for_one)
IO.puts("Sake dev server on http://localhost:4000 (sign in: ana@example.com / secret)")
Process.sleep(:infinity)
