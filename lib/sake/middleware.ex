defmodule Sake.Middleware do
  @moduledoc """
  Host code around every MCP call: audit, rate limits, feature flags and
  plans, argument rewriting, redaction. A middleware is a module with
  `init/1` and `call/2`, as a Plug is, declared on the server for the
  events it handles:

      defmodule MyApp.MCP do
        use Sake.Server, name: "my-app", version: "1.0.0"
        tools [MyApp.MCP.Search, MyApp.MCP.Export]

        middleware :before_request, [{MyApp.MCP.RateLimit, per_minute: 60}]
        middleware :before_call, [MyApp.MCP.Tenant, MyApp.MCP.Audit]
        middleware :after_call, [MyApp.MCP.Redact]
        middleware :after_list, [{MyApp.MCP.Plans, []}]
      end

      defmodule MyApp.MCP.Audit do
        @behaviour Sake.Middleware

        @impl true
        def init(opts), do: opts

        @impl true
        def call(%{tool: tool, arguments: args, ctx: ctx} = payload, _opts) do
          MyApp.Audit.record(ctx.scope, tool.name, args)
          {:cont, payload}
        end
      end

  `call/2` returns `{:cont, payload}` to go on, with the payload as it
  is or changed, or `{:halt, reason}` to refuse. The plugs of an event
  run in the order they are declared, and a halt stops the request: the
  later plugs and events do not run, and the client gets the refusal the
  reason names (see "Halting" below).

  `init/1` is optional and runs once, when the server compiles, like a
  Plug's: what it returns is stored in the server module, so it must be
  plain data (no functions, PIDs or references). Read what changes at
  runtime, such as configuration, in `call/2`.

  ## Events

  Every payload has `:server` (the server module whose plugs run),
  `:method` (the JSON-RPC method), `:ctx` (the request's `Sake.Context`,
  with the principal in `ctx.scope`) and `:assigns`.

  A server mounted in another (`Sake.Server.mount/2`) keeps its
  middleware around its own components, inside the parent's, and its
  plugs see the components by the names it gave them; see
  `guides/composing.md`.

  | Event | Runs | Also in the payload | A plug may change |
  |---|---|---|---|
  | `:before_request` | before every request, any method (not the legacy `initialize`) | `:params` | `:assigns` |
  | `:after_list` | after Sake's own scope and MCP Apps filtering of `tools/list`, `resources/list`, `resources/templates/list` and `prompts/list`, and before any call reaches a component (below) | `:kind` (`:tools`, `:resources` or `:prompts`), `:items` (the specs) | `:items` |
  | `:before_call` | before a tool runs, after its arguments were validated | `:tool`, `:arguments` | `:arguments`, `:assigns` |
  | `:after_call` | after a tool ran, or its task ended | `:tool`, `:arguments`, `:result` | `:result` |
  | `:before_read` | before a resource is read | `:resource`, `:uri`, `:params` | `:params`, `:assigns` |
  | `:after_read` | after a resource was read | `:resource`, `:uri`, `:params`, `:result` | `:result` |
  | `:before_get` | before a prompt is rendered | `:prompt`, `:arguments` | `:arguments`, `:assigns` |
  | `:after_get` | after a prompt was rendered | `:prompt`, `:arguments`, `:result` | `:result` |

  `:tool`, `:resource` and `:prompt` are the component's spec
  (`Sake.Tool.Spec`, `Sake.Resource.Spec`, `Sake.Prompt.Spec`).
  `:arguments` are what the component receives (atom keys), `:params`
  a resource template's parameters, and `:result` the result as the
  client gets it (a `CallToolResult`, `ReadResourceResult` or
  `GetPromptResult` with string keys). Sake reads back only the keys in
  the last column; a plug that continues with one of them of the wrong
  shape fails the request, as one that raises does.

  ## Assigns

  `:assigns` carries a decision from the `before_` plugs to the later
  plugs of the same request, and to the component, which reads it as
  `ctx.assigns`. It starts as `%{}`; put your keys into the map rather
  than replace it. It belongs to one request: a retry with the client's
  input (the modern protocol's `requestState`) is a request of its own
  and starts again from `%{}`, and the `:before_` events run again on
  it. A task's `:after_call` gets the assigns of the `tools/call` that
  started it.

  ## Hiding components

  An `:after_list` plug that drops a component from `:items` hides it
  everywhere, not only in the list: before a call, a read, a prompt, a
  completion or a subscription reaches a component, Sake runs the
  `:after_list` plugs again with `:items` holding just that component
  (and `:method` naming the request), and a component they drop is
  answered as one that does not exist. So the list and the call always
  agree, from one plug. With `:after_list` plugs, list results are
  `cacheScope: "private"`, as they now differ between principals.

  ## Halting

  The reason decides what the client gets; anything else is refused
  without saying why, so an internal reason never reaches the client.

    * `:not_found` — the answer for a component or method that does not
      exist (`-32602` "Unknown tool: …", for instance).
    * `{:forbidden, scopes}` — the answer for missing scopes: on HTTP a
      403 whose `WWW-Authenticate` challenge names `scopes`, so the
      client can step up to them.
    * `:forbidden` — a 403 (on HTTP) with no challenge, for a refusal no
      scope would lift.
    * `{:error, message}` — a `-32600` error with `message`.
    * `{:tool_error, message}` — on `:before_call` and `:after_call`, a
      tool result with `isError: true` and `message`, which the model
      reads; on other events, as `{:error, message}`.
    * anything else — a `-32600` error, "Request refused".

  A plug that raises, throws or exits counts as a halt: it is logged and
  the client gets a `-32603` error, "The request failed.". The request
  process carries on.

  ## Observing

  Middleware decides; telemetry observes. `[:sake, :server, :request]`
  covers every request, refused ones too, and a halt emits
  `[:sake, :middleware, :halt]` with the event, the plug, the reason
  and the request's `method`, `component`, `era`, `protocol_version`
  and `client_name`. With OpenTelemetry, the request's span gets
  `sake.middleware.event` and `sake.middleware.plug`.

  See `guides/middleware.md` for worked examples.
  """

  @typedoc "The events a server can declare middleware for."
  @type event ::
          :before_request
          | :after_list
          | :before_call
          | :after_call
          | :before_read
          | :after_read
          | :before_get
          | :after_get

  @typedoc "What a plug receives and, changed or not, continues with."
  @type payload :: %{
          required(:server) => module(),
          required(:method) => String.t(),
          required(:ctx) => Sake.Context.t(),
          required(:assigns) => map(),
          optional(atom()) => term()
        }

  @typedoc "Why a plug refused the request; see \"Halting\" for what the client gets."
  @type reason ::
          :not_found
          | :forbidden
          | {:forbidden, [String.t()]}
          | {:error, String.t()}
          | {:tool_error, String.t()}
          | term()

  @callback init(opts :: term()) :: term()
  @callback call(payload(), opts :: term()) :: {:cont, payload()} | {:halt, reason()}
  @optional_callbacks init: 1

  @events [
    :before_request,
    :after_list,
    :before_call,
    :after_call,
    :before_read,
    :after_read,
    :before_get,
    :after_get
  ]

  @doc "The events a server can declare middleware for."
  @spec events() :: [event()]
  def events, do: @events
end
