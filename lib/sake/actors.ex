defmodule Sake.Actors do
  @moduledoc """
  Acting as one of several identities, chosen on each call. A person signs
  in once (their token is theirs), and the host knows the identities they
  may act as: their agents, each with its own name, instructions and
  memory, or an organization's bot for an admin. The model switches
  between them in one connection, without a server entry per identity:

      defmodule MyApp.MCP do
        use Sake.Server, name: "my-app", version: "1.0.0"
        tools [MyApp.MCP.EditPage]
        actors MyApp.MCP.Actors
      end

      defmodule MyApp.MCP.Actors do
        @behaviour Sake.Actors
        alias Sake.Actors.Actor

        @impl true
        def list(ctx) do
          for agent <- MyApp.Agents.of(ctx.scope) do
            %Actor{id: "agent:\#{agent.id}", name: agent.name, instructions: agent.persona, data: agent}
          end
        end
      end

  With `actors`, the server has two tools more, and every other tool one
  optional argument:

    * `list_actors` lists who the principal may act as, and which of them
      a call without `as` acts as (`default/1`).
    * `act_as` takes an actor's `id` and returns its name and
      instructions, for the model to take on its persona, with the `as` to
      pass from then on.
    * `as` (a string, optional) on every other tool: the `id` of the actor
      the call acts as. Sake takes it out of the arguments before they are
      validated, asks `fetch/2` for the actor, and sets `ctx.actor`; the
      tool, its middleware and its task see the actor there. An `as` the
      principal may not act as is a tool error, which names `list_actors`.
      A call without `as` acts as `default/1`, `nil` unless the host says
      otherwise: the principal themselves.

  ## Why on every call

  The protocol is stateless from `2026-07-28`: no session holds a choice
  between two requests. So the actor travels with each call, as an
  argument the model passes back, as the specification advises for any
  state across calls. Nothing is trusted: `fetch/2` checks every `as`
  against the principal (`ctx.scope`) on every call, so a model can act
  only as an identity its person may. The principal stays the token's
  subject; the actor is who acts for them, as in OAuth Token Exchange's
  `act` claim (RFC 8693). When clients pick an identity themselves and
  send it in the token, only where the host reads the actor changes.

  ## The callbacks

    * `list/1` (required): the actors of the request's principal, in the
      order the model sees them.
    * `fetch/2` (optional): the actor of an `id`, or `:error` when the
      principal may not act as it. By default, the one of `list/1` with
      that `id`; a host with many actors per principal looks one up.
    * `default/1` (optional): the actor of a call without `as`, or `nil`
      for the principal themselves (the default).

  A tool that declares an argument named `as` keeps it: Sake neither adds
  nor takes it, and its calls act as `default/1`. A server's `actors`
  apply to the tools it serves, its mounted servers' and its proxied
  upstreams' included; an upstream never sees `as`. Resources and prompts
  are read as the principal.
  """

  alias Sake.Actors.Actor

  @callback list(ctx :: Sake.Context.t()) :: [Actor.t()]
  @callback fetch(ctx :: Sake.Context.t(), id :: String.t()) :: {:ok, Actor.t()} | :error
  @callback default(ctx :: Sake.Context.t()) :: Actor.t() | nil
  @optional_callbacks fetch: 2, default: 1

  @argument "as"

  @doc "The tools `actors` adds to a server."
  def tools, do: [Sake.Actors.ListActors, Sake.Actors.ActAs]

  @doc "The actors module of the server serving `ctx`, or `nil`."
  def module(%Sake.Context{server: server}) when is_atom(server) and server != nil do
    if function_exported?(server, :__sake__, 1), do: server.__sake__(:actors)
  end

  def module(_ctx), do: nil

  @doc "The actors of the request's principal."
  def list(module, ctx), do: module.list(ctx)

  @doc "The actor of `id` for the request's principal, or `:error`."
  def fetch(module, ctx, id) when is_binary(id) do
    if function_exported?(module, :fetch, 2),
      do: module.fetch(ctx, id),
      else: Enum.find_value(module.list(ctx), :error, &(&1.id == id && {:ok, &1}))
  end

  def fetch(_module, _ctx, _id), do: :error

  @doc "The actor of a call without `as`."
  def default(module, ctx),
    do: if(function_exported?(module, :default, 1), do: module.default(ctx))

  @doc false
  # Whether Sake adds `as` to this tool: a server with actors, a tool
  # that is not one of theirs and declares no `as` of its own.
  def acting?(nil, _spec), do: false

  def acting?(_module, %{module: module})
      when module in [Sake.Actors.ListActors, Sake.Actors.ActAs], do: false

  def acting?(_module, %{input_schema: schema}),
    do: not Map.has_key?(properties(schema), @argument)

  @doc false
  # The tool as `tools/list` sends it, with `as` among its arguments.
  def to_wire(%{"inputSchema" => schema} = wire, spec, ctx) do
    if acting?(module(ctx), spec),
      do: %{wire | "inputSchema" => with_argument(schema)},
      else: wire
  end

  def to_wire(wire, _spec, _ctx), do: wire

  @doc false
  # Takes `as` out of a call's arguments and puts its actor in `ctx`:
  # `{:ok, arguments, ctx}`, or `{:error, message}` for the model.
  def resolve(spec, arguments, ctx) do
    module = module(ctx)

    if acting?(module, spec) do
      {as, arguments} = Map.pop(arguments || %{}, @argument)
      actor(module, as, ctx, arguments)
    else
      {:ok, arguments, ctx}
    end
  end

  defp actor(module, nil, ctx, arguments),
    do: {:ok, arguments, %{ctx | actor: default(module, ctx)}}

  defp actor(module, as, ctx, arguments) when is_binary(as) do
    case fetch(module, ctx, as) do
      {:ok, %Actor{} = actor} -> {:ok, arguments, %{ctx | actor: actor}}
      _ -> {:error, unknown(as)}
    end
  end

  defp actor(_module, as, _ctx, _arguments), do: {:error, unknown(inspect(as))}

  defp unknown(as),
    do: "You may not act as #{as}. list_actors says who you may act as, and act_as takes on one."

  defp with_argument(schema) do
    property = %{
      "type" => "string",
      "description" =>
        "Who this call acts as: an id from list_actors, after act_as. Leave it out to act as the default."
    }

    schema
    |> Map.put("type", Map.get(schema, "type", "object"))
    |> Map.put("properties", Map.put(properties(schema), @argument, property))
  end

  defp properties(%{"properties" => properties}) when is_map(properties), do: properties
  defp properties(_schema), do: %{}
end
