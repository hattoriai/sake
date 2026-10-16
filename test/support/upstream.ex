defmodule SakeTest.Upstream do
  @moduledoc false
  # The upstream server of the proxy tests: the development server's
  # components, and a few that show what the upstream sees (who called,
  # with which token) and what it answers with (resource links). Served
  # over HTTP by `SakeTest.Upstream.Router`, where the principal is the
  # bearer token the proxy sent.

  defmodule Whoami do
    @moduledoc false
    use Sake.Tool, name: "whoami", description: "Says who called, upstream"

    @impl true
    def execute(_args, ctx), do: {:ok, "upstream sees #{inspect(ctx.scope)}"}
  end

  defmodule Link do
    @moduledoc false
    use Sake.Tool, name: "link", description: "Links an issue and a web page"

    @impl true
    def execute(_args, _ctx) do
      {:ok,
       [
         Sake.Content.text("Two links"),
         Sake.Content.resource_link("issue://1", name: "issue"),
         Sake.Content.resource_link("https://example.com/1", name: "page"),
         Sake.Content.resource("dev://readme", "embedded")
       ]}
    end
  end

  defmodule Changes do
    @moduledoc false
    use Sake.Tool, name: "changes", description: "Announces changes upstream"

    @impl true
    def execute(_args, _ctx) do
      Sake.Server.notify_list_changed(SakeTest.Upstream, :tools)
      Sake.Server.resource_updated(SakeTest.Upstream, "issue://1")
      {:ok, "announced"}
    end
  end

  use Sake.Server,
    name: "upstream",
    version: "1",
    instructions: "The upstream of the proxy tests."

  tools [
    Whoami,
    Link,
    Changes,
    SakeDev.Conformance.Tools.TestToolWithLogging,
    SakeDev.Conformance.Tools.TestInputRequiredResultMultiRound,
    SakeDev.Conformance.Tools.MultiInput
  ]

  mount SakeDev.Server

  @doc false
  # The bearer token, as the upstream's principal.
  def bearer(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> token
      _ -> nil
    end
  end

  @doc "Lets `tokens` through `/strict/mcp`; any other gets a 401."
  def allow(tokens), do: :persistent_term.put({__MODULE__, :allowed}, tokens)

  defmodule Strict do
    @moduledoc false
    import Plug.Conn

    @opts Sake.Plug.init(
            server: SakeTest.Upstream,
            secret: String.duplicate("u", 64),
            scope: &SakeTest.Upstream.bearer/1
          )

    def init(opts), do: opts

    def call(conn, _opts) do
      allowed = :persistent_term.get({SakeTest.Upstream, :allowed}, [])

      if SakeTest.Upstream.bearer(conn) in allowed,
        do: Sake.Plug.call(conn, @opts),
        else: conn |> put_resp_header("www-authenticate", "Bearer") |> send_resp(401, "")
    end
  end

  defmodule Router do
    @moduledoc false
    # `/mcp` takes anyone, with the bearer token (if any) as the
    # principal; `/strict/mcp` answers 401 unless the token is one the
    # test allowed (`SakeTest.Upstream.allow/1`).
    use Plug.Router
    plug :match
    plug :dispatch

    forward "/mcp",
      to: Sake.Plug,
      init_opts: [
        server: SakeTest.Upstream,
        secret: String.duplicate("u", 64),
        scope: &SakeTest.Upstream.bearer/1
      ]

    forward "/strict/mcp", to: SakeTest.Upstream.Strict

    match _, do: send_resp(conn, 404, "")
  end
end
