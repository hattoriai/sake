defmodule Sake.Server.Dispatch do
  @moduledoc false
  # The modern (2026-07-28) methods. `handle/3` wraps results with
  # resultType and server info; the bare functions are shared with the
  # legacy dispatcher.

  require Logger

  alias Sake.{Context, JSONRPC, Protocol, Server}
  alias Sake.Server.{Cursor, Results}

  @type outcome ::
          {:reply, map()}
          | {:error, map()}
          | {:forbidden, [String.t()]}
          | {:listen, map()}
          | :noreply

  @spec handle(module(), JSONRPC.parsed(), Context.t()) :: outcome()
  def handle(_server, {:notification, _method, _params}, _ctx), do: :noreply

  def handle(server, {:request, id, method, params}, ctx) do
    ctx = %{ctx | request_id: id, method: method, server: server}

    case dispatch(server, method, params, ctx) do
      {:ok, result} -> {:reply, finish(result, server, ctx)}
      {:error, code, message} -> {:error, error(code, message)}
      {:error, code, message, data} -> {:error, Map.put(error(code, message), "data", data)}
      {:forbidden, scopes} -> {:forbidden, scopes}
      {:listen, filter} -> {:listen, filter}
    end
  end

  defp dispatch(server, "server/discover", _params, ctx) do
    {:ok,
     %{
       "supportedVersions" => [Protocol.modern()],
       "capabilities" => capabilities(server),
       "instructions" => server.__sake__(:instructions)
     }
     |> Map.reject(fn {_, v} -> is_nil(v) end)
     |> cacheable(server, ctx)}
  end

  defp dispatch(server, "tools/list", params, ctx), do: list_tools(server, params, ctx)
  defp dispatch(server, "tools/call", params, ctx), do: call_tool(server, params, ctx)
  defp dispatch(server, "resources/list", params, ctx), do: list_resources(server, params, ctx)

  defp dispatch(server, "resources/templates/list", params, ctx),
    do: list_resource_templates(server, params, ctx)

  defp dispatch(server, "resources/read", params, ctx), do: read_resource(server, params, ctx)
  defp dispatch(server, "prompts/list", params, ctx), do: list_prompts(server, params, ctx)
  defp dispatch(server, "prompts/get", params, ctx), do: get_prompt(server, params, ctx)
  defp dispatch(server, "completion/complete", params, ctx), do: complete(server, params, ctx)

  defp dispatch(_server, "subscriptions/listen", %{"notifications" => filter}, _ctx)
       when is_map(filter),
       do: {:listen, filter}

  defp dispatch(_server, "subscriptions/listen", _params, _ctx), do: {:listen, %{}}

  defp dispatch(_server, _method, _params, _ctx),
    do: {:error, JSONRPC.code(:method_not_found), "Method not found"}

  @doc false
  def capabilities(server) do
    caps = Server.capabilities(server)
    ext = server.__sake__(:extensions)
    if ext == %{}, do: caps, else: Map.put(caps, "extensions", ext)
  end

  # ---- lists

  @doc false
  def list_tools(server, params, ctx) do
    with {:ok, offset} <- offset(params, ctx) do
      specs = server.__sake__(:tools) |> Enum.filter(&Server.allowed?(&1, ctx))
      {page, next} = page(specs, offset, server)

      {:ok,
       %{"tools" => Enum.map(page, &Sake.Tool.Spec.to_wire(&1, ctx.protocol_version))}
       |> next_cursor(next, ctx)
       |> cacheable(server, ctx, Enum.map(page, & &1.ttl))}
    end
  end

  @doc false
  def list_resources(server, params, ctx) do
    with {:ok, offset} <- offset(params, ctx) do
      entries =
        server.__sake__(:resources)
        |> Enum.filter(&Server.allowed?(&1, ctx))
        |> Enum.flat_map(&resource_entries(&1, ctx))

      {page, next} = page(entries, offset, server)
      {ttls, page} = Enum.unzip(page)

      {:ok, %{"resources" => page} |> next_cursor(next, ctx) |> cacheable(server, ctx, ttls)}
    end
  end

  # Each entry travels with its component's ttl, for the page's `ttlMs`.
  defp resource_entries(%{template: false} = spec, ctx),
    do: [{spec.ttl, Sake.Resource.Spec.to_wire(spec, ctx.protocol_version)}]

  defp resource_entries(spec, ctx) do
    if Code.ensure_loaded?(spec.module) and function_exported?(spec.module, :list, 1) do
      Enum.map(
        spec.module.list(ctx),
        &{spec.ttl, Sake.Resource.Spec.listed_to_wire(spec, &1, ctx.protocol_version)}
      )
    else
      []
    end
  end

  @doc false
  def list_resource_templates(server, params, ctx) do
    with {:ok, offset} <- offset(params, ctx) do
      specs =
        server.__sake__(:resources) |> Enum.filter(&(&1.template and Server.allowed?(&1, ctx)))

      {page, next} = page(specs, offset, server)

      {:ok,
       %{
         "resourceTemplates" =>
           Enum.map(page, &Sake.Resource.Spec.template_to_wire(&1, ctx.protocol_version))
       }
       |> next_cursor(next, ctx)
       |> cacheable(server, ctx, Enum.map(page, & &1.ttl))}
    end
  end

  @doc false
  def list_prompts(server, params, ctx) do
    with {:ok, offset} <- offset(params, ctx) do
      specs = server.__sake__(:prompts) |> Enum.filter(&Server.allowed?(&1, ctx))
      {page, next} = page(specs, offset, server)

      {:ok,
       %{"prompts" => Enum.map(page, &Sake.Prompt.Spec.to_wire(&1, ctx.protocol_version))}
       |> next_cursor(next, ctx)
       |> cacheable(server, ctx, Enum.map(page, & &1.ttl))}
    end
  end

  defp offset(%{"cursor" => cursor}, ctx) do
    case Cursor.decode(ctx.secret, cursor) do
      {:ok, offset} -> {:ok, offset}
      :error -> {:error, JSONRPC.code(:invalid_params), "Invalid cursor"}
    end
  end

  defp offset(_params, _ctx), do: {:ok, 0}

  defp page(items, offset, server) do
    size = server.__sake__(:page_size)
    page = items |> Enum.drop(offset) |> Enum.take(size)
    next = if length(items) > offset + size, do: offset + size
    {page, next}
  end

  defp next_cursor(result, nil, _ctx), do: result

  defp next_cursor(result, next, ctx),
    do: Map.put(result, "nextCursor", Cursor.encode(ctx.secret, next))

  # ---- tools/call

  @doc false
  def call_tool(server, %{"name" => name} = params, ctx) when is_binary(name) do
    with {:ok, spec} <- find_tool(server, name),
         :ok <- allowed(spec, ctx) do
      call_validated(spec, params, ctx)
    end
  end

  def call_tool(_server, _params, _ctx),
    do: {:error, JSONRPC.code(:invalid_params), "tools/call needs a tool name"}

  defp call_validated(spec, params, ctx) do
    raw_args = params["arguments"] || %{}

    case Sake.Schema.validate(spec.input_schema, raw_args) do
      {:ok, args} ->
        with_inputs(spec.name, raw_args, params, ctx, fn ctx ->
          {:ok, run_tool(spec, args, ctx)}
        end)

      {:error, errors} ->
        {:ok, Results.tool({:error, "Invalid arguments: " <> format_errors(errors)}, spec, ctx)}
    end
  end

  defp find_tool(server, name) do
    case Server.tool(server, name) do
      {:ok, spec} -> {:ok, spec}
      :error -> {:error, JSONRPC.code(:invalid_params), "Unknown tool: #{name}"}
    end
  end

  defp allowed(spec, ctx),
    do: if(Server.allowed?(spec, ctx), do: :ok, else: {:forbidden, spec.scopes})

  defp run_tool(spec, args, ctx) do
    Results.tool(spec.module.execute(args, ctx), spec, ctx)
  rescue
    exception ->
      if ctx.reraise, do: reraise(exception, __STACKTRACE__)

      Logger.error(
        "tool #{spec.name} failed: " <> Exception.format(:error, exception, __STACKTRACE__)
      )

      Results.tool({:error, "The tool failed."}, spec, ctx)
  end

  defp format_errors(errors) do
    Enum.map_join(errors, "; ", fn %{path: path, message: m} ->
      Enum.join(path, ".") <> ": " <> m
    end)
  end

  # ---- resources/read

  @doc false
  def read_resource(server, %{"uri" => uri} = params, ctx) when is_binary(uri) do
    with {:ok, spec, uri_params} <- find_resource(server, uri),
         :ok <- allowed(spec, ctx) do
      with_inputs(uri, %{"uri" => uri}, params, ctx, fn ctx ->
        read_result(spec, uri_params, uri, server, ctx)
      end)
    end
  end

  def read_resource(_server, _params, _ctx),
    do: {:error, JSONRPC.code(:invalid_params), "resources/read needs a uri"}

  defp read_result(spec, uri_params, uri, server, ctx) do
    case Results.resource(spec.module.read(uri_params, ctx), spec, uri, ctx) do
      {:ok, result} -> {:ok, cacheable(result, server, ctx, [spec.ttl])}
      {:error, :not_found} -> {:error, not_found_code(ctx), "Resource not found: #{uri}"}
      {:error, text} -> {:error, JSONRPC.code(:internal), text}
    end
  end

  defp find_resource(server, uri) do
    case Server.resource(server, uri) do
      {:ok, spec, params} -> {:ok, spec, params}
      :error -> {:error, JSONRPC.code(:invalid_params), "Resource not found: #{uri}"}
    end
  end

  defp not_found_code(%Context{era: :legacy}), do: JSONRPC.code(:legacy_resource_not_found)
  defp not_found_code(_), do: JSONRPC.code(:invalid_params)

  # ---- prompts/get

  @doc false
  def get_prompt(server, %{"name" => name} = params, ctx) when is_binary(name) do
    with {:ok, spec} <- find_prompt(server, name),
         :ok <- allowed(spec, ctx),
         {:ok, args} <- prompt_args(spec, params["arguments"] || %{}) do
      with_inputs(name, params["arguments"] || %{}, params, ctx, fn ctx ->
        prompt_result(spec, args, ctx)
      end)
    end
  end

  def get_prompt(_server, _params, _ctx),
    do: {:error, JSONRPC.code(:invalid_params), "prompts/get needs a name"}

  defp prompt_result(spec, args, ctx) do
    case Results.prompt(spec.module.get(args, ctx), spec, ctx) do
      {:ok, result} -> {:ok, result}
      {:error, text} -> {:error, JSONRPC.code(:invalid_params), text}
    end
  end

  defp find_prompt(server, name) do
    case Server.prompt(server, name) do
      {:ok, spec} -> {:ok, spec}
      :error -> {:error, JSONRPC.code(:invalid_params), "Unknown prompt: #{name}"}
    end
  end

  defp prompt_args(spec, given) do
    Enum.reduce_while(spec.args, {:ok, %{}}, fn arg, {:ok, acc} ->
      case Map.fetch(given, arg.name) do
        {:ok, v} when is_binary(v) ->
          {:cont, {:ok, Map.put(acc, String.to_atom(arg.name), v)}}

        {:ok, _} ->
          {:halt,
           {:error, JSONRPC.code(:invalid_params), "Prompt argument #{arg.name} must be a string"}}

        :error when arg.required ->
          {:halt, {:error, JSONRPC.code(:invalid_params), "Missing prompt argument: #{arg.name}"}}

        :error ->
          {:cont, {:ok, Map.put(acc, String.to_atom(arg.name), nil)}}
      end
    end)
  end

  # ---- the multi round-trip machinery shared by tools/call, resources/read
  # and prompts/get: a component's elicitation call throws to unwind here,
  # and the resulting `requestState` is verified on the next round-trip.

  defp with_inputs(name, args, params, ctx, fun) do
    case resolve_inputs(name, args, params, ctx) do
      :error ->
        {:error, JSONRPC.code(:invalid_params), "Invalid request state"}

      {:error, :missing_state} ->
        {:error, JSONRPC.code(:invalid_params), "Missing request state"}

      {:ok, inputs} ->
        run_with_inputs(name, args, ctx, inputs, fun)
    end
  end

  defp resolve_inputs(name, args, %{"requestState" => state} = params, ctx) do
    case Sake.Server.RequestState.verify(ctx, name, args, state) do
      {:ok, previous} -> {:ok, Map.merge(previous, params["inputResponses"] || %{})}
      :error -> :error
    end
  end

  # `inputResponses` are only ever honoured alongside the signed
  # `requestState` that proves Sake asked for them; on its own it would let
  # any client inject forged elicitation answers on the first call.
  defp resolve_inputs(_name, _args, %{"inputResponses" => _responses}, _ctx),
    do: {:error, :missing_state}

  defp resolve_inputs(_name, _args, _params, _ctx), do: {:ok, %{}}

  defp run_with_inputs(name, args, ctx, inputs, fun) do
    ctx = %{ctx | inputs: inputs}

    try do
      fun.(ctx)
    catch
      :throw, {:sake_input_required, key, request} ->
        {:ok,
         %{
           "resultType" => "input_required",
           "inputRequests" => %{key => request},
           "requestState" => Sake.Server.RequestState.sign(ctx, name, args, inputs)
         }}
    end
  end

  # ---- completion/complete

  @doc false
  def complete(server, %{"ref" => ref, "argument" => %{"name" => arg, "value" => value}}, ctx) do
    case resolve_completion_ref(server, ref) do
      %{module: _} = spec -> run_completion(spec, arg, value, ctx)
      _ -> {:error, JSONRPC.code(:invalid_params), "Unknown completion reference"}
    end
  end

  def complete(_server, _params, _ctx),
    do: {:error, JSONRPC.code(:invalid_params), "completion/complete needs a ref and an argument"}

  defp resolve_completion_ref(server, %{"type" => "ref/prompt", "name" => name}) do
    with({:ok, s} <- Server.prompt(server, name), do: s)
  end

  defp resolve_completion_ref(server, %{"type" => "ref/resource", "uri" => uri}),
    do: Enum.find(server.__sake__(:resources), &(&1.uri == uri))

  defp resolve_completion_ref(_server, _ref), do: :error

  defp run_completion(spec, arg, value, ctx) do
    cond do
      not Server.allowed?(spec, ctx) -> {:forbidden, spec.scopes}
      not completable?(spec.module) -> {:ok, completion([], [])}
      true -> complete_with(spec.module, arg, value, ctx)
    end
  end

  defp completable?(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :complete, 3)

  defp complete_with(module, arg, value, ctx) do
    case module.complete(arg, value, ctx) do
      {:ok, values} -> {:ok, completion(values, [])}
      {:ok, values, opts} -> {:ok, completion(values, opts)}
    end
  end

  defp completion(values, opts) do
    values = Enum.take(values, 100)
    c = %{"values" => values, "hasMore" => opts[:has_more] || false}
    %{"completion" => if(opts[:total], do: Map.put(c, "total", opts[:total]), else: c)}
  end

  # ---- wrapping

  # `ttlMs` is the shortest of the server's ttl and the ttl of every
  # component the result lists (or, for a read, the one component read):
  # a client that caches the result must not keep any entry longer than
  # its own component allows.
  @doc false
  def cacheable(result, server, ctx, component_ttls \\ [])

  def cacheable(result, server, %Context{era: :modern} = ctx, component_ttls) do
    scope =
      server.__sake__(:cache_scope) ||
        if(ctx.token == nil and ctx.conn_assigns[:sake_auth] != true, do: :public, else: :private)

    ttl = Enum.min([server.__sake__(:ttl) | Enum.reject(component_ttls, &is_nil/1)])
    result |> Map.put("ttlMs", ttl) |> Map.put("cacheScope", to_string(scope))
  end

  def cacheable(result, _server, _ctx, _component_ttls), do: result

  @doc false
  def finish(result, server, %Context{era: :modern}) do
    info = server.__sake__(:info)

    meta =
      Map.merge(result["_meta"] || %{}, %{
        Protocol.meta(:server_info) => %{"name" => info.name, "version" => info.version}
      })

    result |> Map.put_new("resultType", "complete") |> Map.put("_meta", meta)
  end

  def finish(result, _server, _ctx), do: result

  defp error(code, message), do: %{"code" => code, "message" => message}
end
