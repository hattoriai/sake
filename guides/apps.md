# MCP Apps

An MCP App is an interactive HTML interface that a server ships with a
tool: a chart, a form, a board. When the model calls the tool, a host
that supports apps (Claude, ChatGPT, VS Code, Goose and others) renders
the app in a sandboxed iframe inside the conversation, hands it the
tool's result, and lets it call the server's tools back. This is the
`io.modelcontextprotocol/ui` extension, in its 2026-01-26 revision.

The pieces:

- a **UI resource**: an HTML document at a `ui://` URI, with the MIME
  type `text/html;profile=mcp-app`, served by `resources/read`;
- a **tool** that names that URI in its `_meta.ui.resourceUri`;
- the **app**, the script in the document, which talks to the host over
  `postMessage` JSON-RPC (`ui/initialize`, the tool's input and result as
  notifications, `tools/call` back to the server through the host).

Sake does the first two and serves the third; the app is HTML and
JavaScript you write.

## Declaring a UI

```elixir
defmodule MyApp.MCP.SalesMap do
  use Sake.UI,
    uri: "ui://my-app/sales-map",
    name: "sales_map",
    title: "Sales map",
    template: "sales_map.html.eex",
    csp: [resource_domains: ["https://tile.openstreetmap.org"]],
    prefers_border: true

  @impl true
  def assigns(ctx), do: %{region: ctx.scope.region}
end
```

`use Sake.UI` options: `uri` (required; a fixed `ui://` URI), `name`
(default: the module's last segment, snake-cased), `title`,
`description`, `icons`, `scope`, `ttl` and `meta` (as for any resource),
`template` (below), and the `_meta.ui` the host reads: `csp`,
`permissions`, `domain` and `prefers_border` (see Security below).

A UI is a resource, so it is listed with the others:

```elixir
defmodule MyApp.MCP do
  use Sake.Server, name: "my-app", version: "1.0.0"
  tools [MyApp.MCP.ShowSales, MyApp.MCP.SalesFor]
  resources [MyApp.MCP.Readme, MyApp.MCP.SalesMap]
end
```

The server then advertises the extension in its capabilities
(`server/discover`, and `initialize` on a legacy session), and its
`_meta.ui` travels both on the `resources/list` entry, where a host can
review it before any tool runs, and on the `resources/read` contents.

## Linking a tool

```elixir
defmodule MyApp.MCP.ShowSales do
  use Sake.Tool,
    name: "show_sales",
    description: "Shows the quarter's sales on a map",
    scope: "sales:read",
    ui: MyApp.MCP.SalesMap

  arg :quarter, :string, required: true

  @impl true
  def execute(%{quarter: quarter}, ctx) do
    {:ok, %{quarter: quarter, regions: Sales.by_region(ctx.scope, quarter)}}
  end
end
```

`ui:` names the `Sake.UI` module. The server checks at compile time that
the UI is among its resources, since the host fetches it from there.

The result does two jobs. A map returned from `execute/2` goes out as
`structuredContent` (the data the app renders) *and* as JSON text in
`content`, which is what the model reads, and what a client that shows no
app gets: the specification requires a tool with a UI to return
meaningful content all the same. Keep the result small enough for the
model to read, or give the model its own text with `text:`, and the app
still gets the whole map:

```elixir
def execute(args, ctx) do
  chart = build_chart(args, ctx)
  {:ok, chart, text: "Bar chart of signups by week: #{length(chart.rows)} rows"}
end
```

Anything only the app needs can also come from a second tool the app
calls.

## App-only tools

```elixir
defmodule MyApp.MCP.SalesFor do
  use Sake.Tool,
    name: "sales_for",
    description: "One region's sales, for the sales map",
    scope: "sales:read",
    ui: MyApp.MCP.SalesMap,
    visibility: [:app]

  arg :region, :string, required: true

  @impl true
  def execute(%{region: region}, ctx), do: {:ok, Sales.region(ctx.scope, region)}
end
```

`visibility:` is `[:model, :app]` by default: the model sees the tool and
an app may call it. `[:app]` hides it from the model (a refresh button,
a form submission, paging through data the board shows); `[:model]`
keeps apps from calling it. The host enforces both. A tool can be
app-only without `ui:` of its own: any app of the same server may call
it.

Visibility is about what the model sees, not authorization: an app runs
with the person's connection, and anything that can call the server can
call an app-only tool. Protect what needs protecting with `scope:`, as
for any tool.

## What a client sees

A client renders apps when it declares the extension with the MCP App
MIME type, `extensions: {"io.modelcontextprotocol/ui": {mimeTypes:
["text/html;profile=mcp-app"]}}` — in each request's capabilities on the
modern protocol, in `initialize` on a legacy session. For such a host,
Sake lists:

- each tool with its `_meta.ui` (`resourceUri` and `visibility`), plus
  the deprecated flat `_meta["ui/resourceUri"]` key, as the official SDK
  still sends it for hosts that read only that one;
- the app-only tools;
- the UI resources in `resources/list`.

Any other client gets the tools as plain tools, without `_meta.ui`, and
neither the app-only tools nor the UI resources: they are of no use
without a host that renders the app. A `tools/call` for an app-only tool
from such a client is answered as for an unknown tool. A UI resource can
still be read by anyone.

`Sake.UI.supported?/1` tells a tool whether the current client renders
apps, for a tool that words its text differently when it does.

Since `tools/list` and `resources/list` now depend on the client's
capabilities, on a server with any UI they carry `cacheScope: "private"`
on the modern protocol: a shared cache must not hand the list a client
without apps got to a host, or the other way around. The UI document
itself is the same for every client and keeps the server's cache scope.

## Security: CSP, permissions, domain

The host renders the document in a sandbox with a strict Content Security
Policy: no network access, no external scripts, styles, images or fonts,
no nested frames. Declare what the app needs:

```elixir
use Sake.UI,
  uri: "ui://my-app/sales-map",
  template: "sales_map.html.eex",
  csp: [
    connect_domains: ["https://api.example.com"],
    resource_domains: ["https://tile.openstreetmap.org"],
    frame_domains: ["https://www.youtube.com"],
    base_uri_domains: ["https://cdn.example.com"]
  ],
  permissions: [:clipboard_write],
  domain: "a904794854a047f6.claudemcpcontent.com",
  prefers_border: true
```

- `csp`: `connect_domains` (fetch, XHR, WebSocket), `resource_domains`
  (scripts, styles, images, fonts, media), `frame_domains` (nested
  iframes) and `base_uri_domains`. A host may restrict further, never
  loosen.
- `permissions`: `:camera`, `:microphone`, `:geolocation`,
  `:clipboard_write`. The host may grant them; an app should still detect
  the feature before using it.
- `domain`: a stable origin for the sandbox, for an API that allowlists
  origins with CORS. Its format belongs to each host (Claude derives one
  from your server's URL), so read the host's documentation.
- `prefers_border`: whether the host should draw a border and background
  around the app. Say so either way; hosts' defaults differ.

The simplest app needs none of it: everything in one document, with the
data coming from the tool's result and from tool calls through the host.

## The document

### `render/1`

```elixir
@impl true
def render(_ctx) do
  """
  <!doctype html>
  <html>
    <body>
      <div id="map"></div>
      <script>#{inline("priv/static/assets/sales_map.js")}</script>
    </body>
  </html>
  """
end
```

`render/1` gets the request's `Sake.Context` and returns the whole
document as a string or iodata (or `{:safe, iodata}`). It runs on every
`resources/read`; a host may fetch the document before the tool runs and
cache it, so the per-call data belongs in the tool's result, not here.

### EEx templates

`template: "sales_map.html.eex"`, relative to the module's own file, is
compiled into the module as `render/1`. Its assigns come from the
optional `assigns/1`:

```eex
<!doctype html>
<html>
  <head><title><%= @title %></title></head>
  <body>
    <h1><%= @title %></h1>
    <script><%= raw inline("priv/static/assets/sales_map.js") %></script>
  </body>
</html>
```

`<%= %>` escapes its output as HTML; `raw/1` marks what must go in as it
is.

### Inlining bundled assets

`inline/1` reads a file, relative to the project's root, at compile time
and puts its contents in the document; the template does the same with
`raw inline(...)`. The template and every inlined file are external
resources of the module: change one and the module recompiles. So the
document is one self-contained file built from the assets your existing
pipeline produces. With Phoenix's esbuild:

```elixir
# config/config.exs
config :esbuild,
  sales_map: [
    args: ~w(js/sales_map.js --bundle --minify --format=iife --outdir=../priv/static/assets),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]
```

Build the bundle before compiling (`mix esbuild sales_map`, or the
`assets.build` alias) and inline `priv/static/assets/sales_map.js`. The
same goes for a Tailwind stylesheet in a `<style>` tag.

### HEEx and Phoenix components

When the host has `phoenix_html` (every Phoenix application does),
`render/1` may return what a function component returns, or anything
else that implements `Phoenix.HTML.Safe`:

```elixir
defmodule MyApp.MCP.SalesMap do
  use Sake.UI, uri: "ui://my-app/sales-map", prefers_border: true
  import MyAppWeb.SalesComponents

  @impl true
  def render(ctx), do: sales_map_document(%{region: ctx.scope.region})
end

defmodule MyAppWeb.SalesComponents do
  use Phoenix.Component
  require Sake.UI

  @script Sake.UI.inline("priv/static/assets/sales_map.js")

  def sales_map_document(assigns) do
    assigns = assign(assigns, :script, @script)

    ~H"""
    <!doctype html>
    <html>
      <body>
        <h1>Sales in {@region}</h1>
        <div id="map"></div>
        <script><%= Phoenix.HTML.raw(@script) %></script>
      </body>
    </html>
    """
  end
end
```

Sake turns it into the document with `Phoenix.HTML.Safe.to_iodata/1`.
Without `phoenix_html`, do the same yourself and return the iodata.

LiveView itself has no place inside the app: the document runs in the
host's sandbox, on an origin that is not your application's, with no
session cookie and no CSRF token, and a LiveView socket would need a
`connect_domains` entry and its own authentication. Render with
components, and let the app get its data through the host's tool calls,
which carry the person's authorization to your server.

## The app

The app talks to the host with JSON-RPC over `postMessage`. A small app
needs no library:

```js
let nextId = 1;
const pending = new Map();
const send = (m) => window.parent.postMessage({ jsonrpc: "2.0", ...m }, "*");
const request = (method, params) =>
  new Promise((resolve, reject) => {
    const id = nextId++;
    pending.set(id, { resolve, reject });
    send({ id, method, params });
  });

window.addEventListener("message", (event) => {
  const m = event.data;
  if (m?.jsonrpc !== "2.0") return;
  if (m.method === undefined) {
    const p = pending.get(m.id);
    pending.delete(m.id);
    m.error ? p?.reject(new Error(m.error.message)) : p?.resolve(m.result);
  } else if (m.method === "ui/notifications/tool-result") {
    render(m.params.structuredContent);
  } else if (m.method === "ui/resource-teardown") {
    send({ id: m.id, result: {} });
  }
});

await request("ui/initialize", {
  protocolVersion: "2026-01-26",
  appInfo: { name: "Sales map", version: "1.0.0" },
  appCapabilities: { availableDisplayModes: ["inline"] }
});
send({ method: "ui/notifications/initialized", params: {} });

// Later, on a click:
const result = await request("tools/call", { name: "sales_for", arguments: { region: "north" } });
```

The development server's issue board (`dev/lib/sake_dev/ui/`) is a
complete app of this kind: it also follows the host's theme and reports
its size with `ui/notifications/size-changed`, so that the host can size
the frame.

For anything bigger, use the official SDK,
[`@modelcontextprotocol/ext-apps`](https://www.npmjs.com/package/@modelcontextprotocol/ext-apps):
its `App` class does the handshake, the notifications (`ontoolresult`,
`ontoolinput`, `onhostcontextchanged`), `callServerTool`, `sendMessage`,
`updateModelContext`, `openLink`, display modes, automatic resizing, and
the host's theme and fonts. Install it in `assets/` with npm, import it
from your app's entry point, bundle it with esbuild as above, and inline
the bundle. Sake ships no JavaScript of its own for this.

## Hosts

Claude (web and desktop), ChatGPT, VS Code with GitHub Copilot, Microsoft
365 Copilot, Goose, Postman, MCPJam, Cursor and others render MCP Apps
(the specification's client matrix keeps the current list). A host that
does not still gets the tool and its text, as above.

## Testing

`Sake.Client.connect(url, ui: true)` declares the extension, as a host
would; `list_tools/1` then puts each tool's UI in `spec.ui` (its URI) and
`spec.visibility`, and `read_resource/2` returns the document with its
`_meta`:

```elixir
{:ok, session} = Sake.Client.connect(url, ui: true)
{:ok, tools, session} = Sake.Client.list_tools(session)
%Sake.Tool.Spec{ui: "ui://my-app/sales-map"} = Enum.find(tools, &(&1.name == "show_sales"))
{:ok, [doc], _} = Sake.Client.read_resource(session, "ui://my-app/sales-map")
doc.mime_type #=> "text/html;profile=mcp-app"
```

To see an app run, `mix dev` in this repository serves the issue board:
ask a host connected to it to show the issue board. The ext-apps
repository's `basic-host` example renders apps from a local server
without a model; a remote host such as Claude.ai cannot reach
`localhost`, so expose the development server with a tunnel
(`cloudflared tunnel --url http://localhost:4000`) and add the tunnel's
URL as a connector.
