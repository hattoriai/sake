# Running on several nodes

A load balancer may send each request to any node of a cluster. Most of
what Sake does needs nothing more for that: a modern request carries its
own state, and tools, resources and prompts are the same code on every
node. What Sake *remembers* between requests is another matter: with the
defaults, it is kept in memory on the node that wrote it.

| State | Default (one node) | On several nodes |
|-------|--------------------|------------------|
| The authorization server's codes, tokens, consents, clients | `Sake.Auth.Store.ETS` | `auth: [store: {Sake.Auth.Store.Ecto, repo: MyApp.Repo}]` |
| Tasks | `Sake.Tasks.Store.ETS` | `tasks: [store: {Sake.Tasks.Store.Ecto, repo: MyApp.Repo}]` |
| Single-use JWTs already seen (client assertions, JWT grants, DPoP proofs) | the `auth:` store, else a table on each node | the Ecto `auth:` store, or `replay: {Sake.Auth.Store.Ecto, repo: MyApp.Repo}` |
| Notifications (`list_changed`, resource updates, task status) and a legacy session's subscriptions and answers | the streams of the node that raised them | `pubsub: MyApp.PubSub` |

```elixir
{Sake,
 secret_key_base: {MyAppWeb.Endpoint, :config, [:secret_key_base]},
 pubsub: MyApp.PubSub,
 auth: [store: {Sake.Auth.Store.Ecto, repo: MyApp.Repo}, ...],
 tasks: [store: {Sake.Tasks.Store.Ecto, repo: MyApp.Repo}]}
```

The migrations are `Sake.Auth.Migration` and `Sake.Tasks.Migration`.

What goes wrong without them mostly fails closed, and intermittently:

- **Auth**: a code issued on one node is unknown to the next
  (`invalid_grant`), a refresh token works on one node only, and a
  revocation on one node does not reach a token another node still
  accepts.
- **Tasks**: `tasks/get`, `tasks/update` and `tasks/cancel` answer "Task
  not found" on every node but the one that created the task.
- **Replay**: a JWT used once on one node is accepted again on another
  within its lifetime.
- **Notifications**: a client whose stream is open on another node never
  hears of the change.

A legacy (handshake-era) session also needs `pubsub:`, or session
affinity on `Mcp-Session-Id`; see the protocol versions guide.

Caches stay on each node, by design: Client ID Metadata Documents,
external authorization servers' keys and introspection results, and a
proxy's upstream sessions. Each node fills its own.

## The warning

When any of the state above is kept on one node, Sake watches for this
node to connect to another (a node usually joins its cluster after it
booted) and then logs one warning naming each, with the option that
shares it. Only visible nodes count: a release's `bin/my_app remote`
connects as a hidden node and does not set it off.
