defmodule Sake.Server.Middleware do
  @moduledoc false
  # Runs a server's middleware (`Sake.Middleware`) on the request paths of
  # both eras. Every transport (`Sake.Plug`, its SSE streams, `Sake.Stdio`,
  # `Sake.Test`) reaches the components through `Sake.Server.Dispatch` and
  # `Sake.Server.Legacy`, and those call here, so a plug runs the same way
  # whatever carried the request.
  #
  # A component of a mounted server (`Sake.Server.mount/2`) runs the
  # parent's plugs and its own server's, each server's with the spec (and
  # the URI) as that server knows it: the `before_` events from the
  # outermost server in, the `after_` events from the innermost out, and
  # `:after_list` each mounted server on its own components first. A
  # mounted server's `:before_request` does not run: the request is the
  # parent's.

  require Logger

  alias Sake.{Context, JSONRPC, Trace}
  alias Sake.Server.{Dispatch, Mount, Results}

  # What Sake reads back from a payload, by event; every other key a plug
  # changes is ignored.
  @read_back %{
    before_request: [:assigns],
    after_list: [:items],
    before_call: [:arguments, :assigns],
    after_call: [:result],
    before_read: [:params, :assigns],
    after_read: [:result],
    before_get: [:arguments, :assigns],
    after_get: [:result]
  }

  # The reason a plug that raised, threw or exited halts with. Tagged with
  # this module so that no reason a plug gives can be mistaken for it.
  @failed __MODULE__

  # The events that run from the innermost server out.
  @after_events [:after_list, :after_call, :after_read, :after_get]

  @doc "Whether the server, or a server it mounts, declares middleware for any of `events`."
  @spec any?(module(), [Sake.Middleware.event()]) :: boolean()
  def any?(server, events) do
    Enum.any?(Mount.tree(server), fn {server, _prefixes} ->
      Enum.any?(events, &(pipeline(server, &1) != []))
    end)
  end

  defp pipeline(server, event), do: Map.get(server.__sake__(:middleware), event, [])

  @doc """
  Runs `:before_request`. Returns the context with the assigns its plugs
  left, or the halt.
  """
  @spec before_request(map(), Context.t()) :: {:ok, Context.t()} | {:halt, term()}
  def before_request(params, ctx) do
    case run(ctx.server, :before_request, %{params: params}, ctx) do
      {:cont, payload} -> {:ok, %{ctx | assigns: payload.assigns}}
      {:halt, reason} -> {:halt, reason}
    end
  end

  @doc """
  Runs a `before_` event and returns what it may change (`key`: the
  arguments or the parameters), with the context carrying the assigns.
  """
  @spec before(Sake.Middleware.event(), map(), atom(), Context.t()) ::
          {:ok, term(), Context.t()} | {:halt, term()}
  def before(event, payload, key, ctx) do
    case run_layers(event, payload, ctx) do
      {:cont, payload} -> {:ok, Map.fetch!(payload, key), %{ctx | assigns: payload.assigns}}
      {:halt, reason} -> {:halt, reason}
    end
  end

  @doc "Runs an `after_` event and returns the result its plugs left."
  @spec after_result(Sake.Middleware.event(), map(), Context.t()) ::
          {:ok, map()} | {:halt, term()}
  def after_result(event, payload, ctx) do
    case run_layers(event, payload, ctx) do
      {:cont, payload} -> {:ok, payload.result}
      {:halt, reason} -> {:halt, reason}
    end
  end

  @doc """
  The components of a list the `:after_list` plugs let the client see.
  Only components that were offered can come back: one a plug adds is
  dropped, as no call could reach it.
  """
  @spec filter(:tools | :resources | :prompts | :skills, [struct()], Context.t()) ::
          {:ok, [struct()]} | {:halt, term()}
  def filter(kind, specs, ctx) do
    if any?(ctx.server, [:after_list]),
      do: filter(ctx.server, kind, specs, ctx),
      else: {:ok, specs}
  end

  # Each mounted server's plugs see its own components, as it knows them,
  # before the server's plugs see what they let through.
  defp filter(server, kind, specs, ctx) do
    with {:ok, kept} <- filter_mounted(kind, specs, ctx) do
      specs = Enum.filter(specs, &MapSet.member?(kept, &1))

      if pipeline(server, :after_list) == [],
        do: {:ok, specs},
        else: run_filter(server, kind, specs, ctx)
    end
  end

  defp filter_mounted(kind, specs, ctx) do
    specs
    |> Enum.group_by(&mounted_from/1)
    |> Enum.reduce_while({:ok, MapSet.new()}, fn {from, group}, {:ok, kept} ->
      case kept(from, kind, group, ctx) do
        {:ok, group} -> {:cont, {:ok, MapSet.union(kept, MapSet.new(group))}}
        {:halt, reason} -> {:halt, {:halt, reason}}
      end
    end)
  end

  # The components of one mounted server that its own plugs let through.
  defp kept(nil, _kind, own, _ctx), do: {:ok, own}

  defp kept({server, _prefix}, kind, outer, ctx) do
    inner = Enum.map(outer, fn %{mount: {_, _, spec}} -> spec end)

    with {:ok, survivors} <- filter(server, kind, inner, ctx) do
      keys = MapSet.new(survivors, &key/1)
      {:ok, Enum.filter(outer, fn %{mount: {_, _, spec}} -> MapSet.member?(keys, key(spec)) end)}
    end
  end

  defp mounted_from(%{mount: {server, prefix, _spec}}), do: {server, prefix}
  defp mounted_from(_spec), do: nil

  defp run_filter(server, kind, specs, ctx) do
    case run(server, :after_list, %{kind: kind, items: specs}, ctx) do
      {:cont, %{items: items}} ->
        offered = MapSet.new(specs, &key/1)
        {:ok, Enum.filter(items, &(is_struct(&1) and MapSet.member?(offered, key(&1))))}

      {:halt, reason} ->
        {:halt, reason}
    end
  end

  @doc """
  Whether the `:after_list` plugs let the client reach the component: the
  same plugs that filter the list decide the call, so the two agree. A
  component they drop is `{:halt, :not_found}`.
  """
  @spec listed(:tools | :resources | :prompts | :skills, struct(), Context.t()) ::
          :ok | {:halt, term()}
  def listed(kind, spec, ctx) do
    case filter(kind, [spec], ctx) do
      {:ok, [_]} -> :ok
      {:ok, []} -> {:halt, :not_found}
      {:halt, reason} -> {:halt, reason}
    end
  end

  defp key(%Sake.Resource.Spec{uri: uri}), do: uri
  defp key(%Sake.Skill.Spec{uri: nil, module: module}), do: module
  defp key(%Sake.Skill.Spec{uri: uri}), do: uri
  defp key(%{name: name}), do: name

  @doc """
  What the client gets for a halt, as `Sake.Server.Dispatch` returns it:
  only the reasons `Sake.Middleware` documents say anything, so that an
  internal reason never reaches the client.
  """
  @spec refusal(term(), map(), Context.t()) ::
          {:ok, map()}
          | {:forbidden, [String.t()]}
          | {:insufficient_user_authentication, map()}
          | {:error, integer(), String.t()}
          | {:error, integer(), String.t(), map()}
  def refusal(:not_found, params, ctx), do: not_found(ctx.method, params, ctx)

  def refusal(
        {:insufficient_user_authentication, %{acr_values: acr_values, max_age: max_age} = r},
        params,
        ctx
      ) do
    if is_list(acr_values) and Enum.all?(acr_values, &is_binary/1) and
         (max_age == nil or (is_integer(max_age) and max_age >= 0)) do
      {:insufficient_user_authentication,
       %{
         acr_values: acr_values,
         max_age: max_age,
         reason: reason(Map.get(r, :reason), acr_values),
         scopes: []
       }}
    else
      refusal({:refused, r}, params, ctx)
    end
  end

  def refusal(:forbidden, _params, _ctx), do: {:forbidden, []}

  def refusal({:forbidden, scopes} = reason, params, ctx) when is_list(scopes) do
    if Enum.all?(scopes, &is_binary/1),
      do: {:forbidden, scopes},
      else: refusal({:refused, reason}, params, ctx)
  end

  def refusal({:error, message}, _params, _ctx) when is_binary(message),
    do: {:error, JSONRPC.code(:invalid_request), message}

  def refusal({:tool_error, message}, _params, %Context{method: "tools/call"} = ctx)
      when is_binary(message),
      do: {:ok, Results.tool({:error, message}, nil, ctx)}

  def refusal({:tool_error, message}, _params, _ctx) when is_binary(message),
    do: {:error, JSONRPC.code(:invalid_request), message}

  def refusal({@failed, _kind, _reason}, _params, _ctx),
    do: {:error, JSONRPC.code(:internal), "The request failed."}

  def refusal(_reason, _params, _ctx),
    do: {:error, JSONRPC.code(:invalid_request), "Request refused"}

  # The part of the requirement not met, which the challenge's
  # `error_description` names.
  defp reason(reason, _acr_values) when reason in [:acr, :max_age], do: reason
  defp reason(_reason, []), do: :max_age
  defp reason(_reason, _acr_values), do: :acr

  @doc "Whether a halt is a plug's failure rather than its decision."
  @spec failed?(term()) :: boolean()
  def failed?({@failed, _kind, _reason}), do: true
  def failed?(_reason), do: false

  # `:not_found` is answered exactly as the component's absence would be.
  defp not_found("tools/call", params, _ctx),
    do: {:error, JSONRPC.code(:invalid_params), "Unknown tool: #{params["name"]}"}

  defp not_found("prompts/get", params, _ctx),
    do: {:error, JSONRPC.code(:invalid_params), "Unknown prompt: #{params["name"]}"}

  defp not_found("resources/read", params, ctx), do: Dispatch.not_found(params["uri"], ctx)

  defp not_found("completion/complete", _params, _ctx),
    do: {:error, JSONRPC.code(:invalid_params), "Unknown completion reference"}

  defp not_found("resources/subscribe", params, _ctx),
    do:
      {:error, JSONRPC.code(:invalid_params),
       "Resource does not support subscriptions: #{params["uri"]}"}

  defp not_found("skills/get", params, _ctx),
    do: {:error, JSONRPC.code(:invalid_params), "No skill is served at #{params["uri"]}"}

  defp not_found("resources/directory/read", params, _ctx),
    do:
      {:error, JSONRPC.code(:invalid_params), "#{params["uri"]} is not a directory resource",
       %{"uri" => params["uri"]}}

  defp not_found(_method, _params, _ctx),
    do: {:error, JSONRPC.code(:method_not_found), "Method not found"}

  @doc """
  A result's `cacheScope` once `events` have plugs: what the plugs make
  of a result can differ between principals, so no shared cache may keep
  it.
  """
  @spec cache_scope(map(), module(), [Sake.Middleware.event()]) :: map()
  def cache_scope(%{"cacheScope" => _} = result, server, events) do
    if any?(server, events), do: Map.put(result, "cacheScope", "private"), else: result
  end

  def cache_scope(result, _server, _events), do: result

  # ---- the pipeline

  # An event of one component: the server's plugs, then (or, for an
  # `after_` event, first) those of every server the component was
  # mounted from, each with the component as that server declared it.
  defp run_layers(event, payload, ctx) do
    layers = layers(ctx.server, payload)
    layers = if event in @after_events, do: Enum.reverse(layers), else: layers

    Enum.reduce_while(layers, {:cont, payload}, fn {server, overrides}, {:cont, payload} ->
      case run(server, event, Map.merge(payload, overrides), ctx) do
        {:cont, payload} -> {:cont, {:cont, payload}}
        {:halt, reason} -> {:halt, {:halt, reason}}
      end
    end)
  end

  defp layers(server, payload) do
    case Enum.find([:tool, :resource, :prompt], &Map.has_key?(payload, &1)) do
      nil ->
        [{server, %{}}]

      key ->
        spec = Map.fetch!(payload, key)
        [{server, overrides(key, spec, payload[:uri])} | inner_layers(key, spec, payload[:uri])]
    end
  end

  defp inner_layers(key, %{mount: {server, prefix, inner}}, uri) do
    uri = uri && inner_uri(prefix, uri)
    [{server, overrides(key, inner, uri)} | inner_layers(key, inner, uri)]
  end

  defp inner_layers(_key, _spec, _uri), do: []

  defp inner_uri(prefix, uri) do
    case Mount.unuri(prefix, uri) do
      {:ok, uri} -> uri
      :error -> uri
    end
  end

  defp overrides(key, spec, nil), do: %{key => spec}
  defp overrides(key, spec, uri), do: %{key => spec, uri: uri}

  defp run(server, event, payload, ctx) do
    case pipeline(server, event) do
      [] ->
        {:cont, Map.put_new(payload, :assigns, ctx.assigns)}

      plugs ->
        base = %{method: ctx.method, ctx: ctx, assigns: ctx.assigns}
        run_plugs(plugs, event, base |> Map.merge(payload) |> Map.put(:server, server))
    end
  end

  defp run_plugs([], _event, payload), do: {:cont, payload}

  defp run_plugs([{module, opts} | rest], event, payload) do
    case call(module, opts, event, payload) do
      {:cont, next} ->
        run_plugs(rest, event, next)

      {:halt, reason} ->
        halted(event, module, reason, payload)
        {:halt, reason}
    end
  end

  # A plug that raises, throws, exits or answers with something else
  # halts the request as a failure, logged; the request process carries
  # on. With `reraise` (tests), the exception reaches the test as it was
  # raised, as a component's does. A plug may ask the client for input as
  # a component does (`Sake.Elicit` and the like), which unwinds as a
  # throw on the modern protocol: that one passes through.
  defp call(module, opts, event, payload) do
    module.call(payload, opts) |> checked(module, event, payload)
  catch
    :throw, {:sake_input_required, _} = ask ->
      throw(ask)

    kind, reason ->
      if payload.ctx.reraise, do: :erlang.raise(kind, reason, __STACKTRACE__)

      Logger.error(
        "middleware #{inspect(module)} failed on #{event}: " <>
          Exception.format(kind, reason, __STACKTRACE__)
      )

      {:halt, {@failed, kind, reason}}
  end

  defp checked({:halt, reason}, _module, _event, _payload), do: {:halt, reason}

  defp checked({:cont, %{} = next} = cont, module, event, _payload) do
    case Enum.find(Map.fetch!(@read_back, event), &(not shaped?(&1, Map.get(next, &1)))) do
      nil -> cont
      key -> malformed(module, event, "a #{key} of #{inspect(Map.get(next, key))}")
    end
  end

  defp checked(other, module, event, _payload), do: malformed(module, event, inspect(other))

  defp shaped?(:items, value), do: is_list(value)
  defp shaped?(_key, value), do: is_map(value)

  defp malformed(module, event, what) do
    Logger.error("middleware #{inspect(module)} answered #{event} with #{what}")
    {:halt, {@failed, :error, {:bad_return, module, event}}}
  end

  # Middleware decides and telemetry observes: a halt is an event of its
  # own, emitted where the plug ran, and marks the request's span.
  defp halted(event, module, reason, payload) do
    ctx = payload.ctx
    Trace.halt(event, module)

    :telemetry.execute([:sake, :middleware, :halt], %{system_time: System.system_time()}, %{
      event: event,
      plug: module,
      reason: reason,
      failed: failed?(reason),
      server: ctx.server,
      method: ctx.method,
      component: component(payload),
      era: ctx.era,
      protocol_version: ctx.protocol_version,
      client_name: ctx.client_info["name"]
    })
  end

  defp component(%{tool: %{name: name}}), do: name
  defp component(%{prompt: %{name: name}}), do: name
  defp component(%{uri: uri}), do: uri
  defp component(%{items: [item]}), do: key(item)
  defp component(%{params: %{} = params}), do: params["name"] || params["uri"]
  defp component(_payload), do: nil
end
