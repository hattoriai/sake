defmodule Sake.Server.Dispatch do
  @moduledoc false
  # The modern (2026-07-28) methods. `handle/3` wraps results with
  # resultType and server info; the bare functions are shared with the
  # legacy dispatcher.
  #
  # A proxied component (a spec with a `proxy`, see `Sake.Proxy`) goes
  # through the same checks and middleware as a local one; where a local
  # component's module would run, its request is forwarded upstream
  # (`Sake.Proxy.Forward`). Its arguments are the upstream's to validate,
  # and reach the middleware as the client sent them, with string keys.

  require Logger

  alias Sake.{Context, JSONRPC, Protocol, Server}
  alias Sake.Proxy.Forward
  alias Sake.Server.{Cursor, Middleware, Mount, Results, Tasks, UI}

  @type outcome ::
          {:reply, map()}
          | {:error, map()}
          | {:forbidden, [String.t()]}
          | {:insufficient_user_authentication, map()}
          | {:listen, map()}
          | :noreply

  @spec handle(module(), JSONRPC.parsed(), Context.t()) :: outcome()
  def handle(_server, {:notification, _method, _params}, _ctx), do: :noreply

  def handle(server, {:request, id, method, params}, ctx) do
    ctx = %{ctx | request_id: id, method: method, server: server}

    case request(server, method, params, ctx) do
      {:ok, result} -> {:reply, finish(result, server, ctx)}
      {:error, code, message} -> {:error, error(code, message)}
      {:error, code, message, data} -> {:error, Map.put(error(code, message), "data", data)}
      {:forbidden, scopes} -> {:forbidden, scopes}
      {:insufficient_user_authentication, refusal} -> {:insufficient_user_authentication, refusal}
      {:listen, filter} -> {:listen, filter}
    end
  end

  @doc false
  # `:before_request` runs before every method, so a refusal there (a
  # rate limit, say) costs the server nothing else. Shared with the
  # legacy dispatcher.
  def request(server, method, params, ctx, dispatch \\ &dispatch/4) do
    case Middleware.before_request(params, ctx) do
      {:ok, ctx} -> dispatch.(server, method, params, ctx)
      {:halt, reason} -> Middleware.refusal(reason, params, ctx)
    end
  end

  defp dispatch(server, "server/discover", _params, ctx) do
    {:ok,
     %{
       "supportedVersions" => Protocol.supported(),
       "capabilities" => capabilities(server, ctx),
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

  defp dispatch(server, "tasks/get", params, ctx), do: Tasks.get(server, params, ctx)
  defp dispatch(server, "tasks/update", params, ctx), do: Tasks.update(server, params, ctx)
  defp dispatch(server, "tasks/cancel", params, ctx), do: Tasks.cancel(server, params, ctx)

  defp dispatch(_server, "subscriptions/listen", %{"notifications" => filter}, _ctx)
       when is_map(filter),
       do: {:listen, filter}

  defp dispatch(_server, "subscriptions/listen", _params, _ctx), do: {:listen, %{}}

  defp dispatch(_server, _method, _params, _ctx),
    do: {:error, JSONRPC.code(:method_not_found), "Method not found"}

  @doc false
  def capabilities(server, ctx) do
    caps = Server.capabilities(server)
    ext = extensions(server, ctx)
    if ext == %{}, do: caps, else: Map.put(caps, "extensions", ext)
  end

  # The server's own `extensions:`, plus the tasks extension when a tool
  # can run as a task, MCP Apps when the server has a UI, and the
  # authorization extensions of the endpoint's authorization server.
  # These come from the endpoint, not the server: the same server may be
  # served with and without `auth:`, and the answer is the same for every
  # caller of one endpoint, so `server/discover` stays cacheable as it is.
  defp extensions(server, ctx) do
    ext = server.__sake__(:extensions)

    ext =
      if Tasks.supported?(server),
        do: Map.put_new(ext, Sake.Tasks.extension(), %{}),
        else: ext

    Map.merge(auth_extensions(ctx), UI.extensions(ext, server))
  end

  @doc false
  # The authorization extensions an endpoint with `auth:` advertises. A
  # mounted server is served by its parent's endpoint, so the parent's
  # authorization decides; a proxy's upstream authorizes its own clients,
  # which is not this endpoint's to advertise. An endpoint on an external
  # authorization server declares what its configuration says.
  def auth_extensions(%Context{conn_assigns: %{sake_auth: true}}),
    do: Sake.Auth.config() |> Sake.Auth.extensions() |> extension_map()

  def auth_extensions(%Context{conn_assigns: %{sake_auth: name}}) when name not in [nil, false],
    do: name |> Sake.Auth.External.fetch!() |> Sake.Auth.External.extensions() |> extension_map()

  def auth_extensions(_ctx), do: %{}

  defp extension_map(names), do: Map.new(names, &{Protocol.auth_extension(&1), %{}})

  # ---- lists

  @doc false
  def list_tools(server, params, ctx) do
    with {:ok, offset} <- offset(params, ctx),
         {:ok, specs} <-
           server
           |> Server.tools(ctx)
           |> Enum.filter(&(Server.allowed?(&1, ctx) and UI.visible?(&1, ctx)))
           |> listable(:tools, params, ctx) do
      {page, next} = page(specs, offset, server)

      {:ok,
       %{"tools" => Enum.map(page, &UI.tool_to_wire(&1, ctx))}
       |> next_cursor(next, ctx)
       |> cacheable(server, ctx, Enum.map(page, & &1.ttl))
       |> UI.cache_scope(server)
       |> Middleware.cache_scope(server, [:after_list])
       |> dynamic_scope(server)}
    end
  end

  @doc false
  def list_resources(server, params, ctx) do
    with {:ok, offset} <- offset(params, ctx),
         {:ok, specs} <-
           server
           |> Server.resources(ctx)
           |> Enum.filter(&(Server.allowed?(&1, ctx) and UI.listed?(&1, ctx)))
           |> listable(:resources, params, ctx) do
      entries = Enum.flat_map(specs, &resource_entries(&1, ctx))
      {page, next} = page(entries, offset, server)
      {ttls, page} = Enum.unzip(page)

      {:ok,
       %{"resources" => page}
       |> next_cursor(next, ctx)
       |> cacheable(server, ctx, ttls)
       |> UI.cache_scope(server)
       |> Middleware.cache_scope(server, [:after_list])
       |> dynamic_scope(server)}
    end
  end

  # Each entry travels with its component's ttl, for the page's `ttlMs`.
  defp resource_entries(%{template: false} = spec, ctx),
    do: [{spec.ttl, Sake.Resource.Spec.to_wire(spec, ctx.protocol_version)}]

  defp resource_entries(spec, ctx) do
    if Code.ensure_loaded?(spec.module) and function_exported?(spec.module, :list, 1) do
      for item <- spec.module.list(Mount.component_ctx(spec, ctx)),
          {:ok, item} <- [listed_uri(spec, item)],
          do: {spec.ttl, Sake.Resource.Spec.listed_to_wire(spec, item, ctx.protocol_version)}
    else
      []
    end
  end

  # A mounted template lists its resources by the URIs its server knows;
  # the client knows them under the mount's prefix.
  defp listed_uri(spec, uri) when is_binary(uri), do: Mount.outer_uri(spec, uri)

  defp listed_uri(spec, %{uri: uri} = item) do
    with {:ok, uri} <- Mount.outer_uri(spec, uri), do: {:ok, %{item | uri: uri}}
  end

  @doc false
  def list_resource_templates(server, params, ctx) do
    with {:ok, offset} <- offset(params, ctx),
         {:ok, specs} <-
           server
           |> Server.resources(ctx)
           |> Enum.filter(&(&1.template and Server.allowed?(&1, ctx)))
           |> listable(:resources, params, ctx) do
      {page, next} = page(specs, offset, server)

      {:ok,
       %{
         "resourceTemplates" =>
           Enum.map(page, &Sake.Resource.Spec.template_to_wire(&1, ctx.protocol_version))
       }
       |> next_cursor(next, ctx)
       |> cacheable(server, ctx, Enum.map(page, & &1.ttl))
       |> Middleware.cache_scope(server, [:after_list])
       |> dynamic_scope(server)}
    end
  end

  @doc false
  def list_prompts(server, params, ctx) do
    with {:ok, offset} <- offset(params, ctx),
         {:ok, specs} <-
           server
           |> Server.prompts(ctx)
           |> Enum.filter(&Server.allowed?(&1, ctx))
           |> listable(:prompts, params, ctx) do
      {page, next} = page(specs, offset, server)

      {:ok,
       %{"prompts" => Enum.map(page, &Sake.Prompt.Spec.to_wire(&1, ctx.protocol_version))}
       |> next_cursor(next, ctx)
       |> cacheable(server, ctx, Enum.map(page, & &1.ttl))
       |> Middleware.cache_scope(server, [:after_list])
       |> dynamic_scope(server)}
    end
  end

  # What a proxy lists depends on who asks (each principal has its own
  # upstream session, and maybe its own credentials), so no shared cache
  # may keep it.
  defp dynamic_scope(%{"cacheScope" => _} = result, server) do
    if Server.dynamic?(server), do: Map.put(result, "cacheScope", "private"), else: result
  end

  defp dynamic_scope(result, _server), do: result

  # The `:after_list` plugs see what Sake's own checks (scopes, MCP Apps)
  # let through, and before the list is paged, so that pages stay full.
  defp listable(specs, kind, params, ctx) do
    case Middleware.filter(kind, specs, ctx) do
      {:ok, specs} -> {:ok, specs}
      {:halt, reason} -> Middleware.refusal(reason, params, ctx)
    end
  end

  @doc false
  # Whether the `:after_list` plugs let the request reach the component,
  # answered as the list would be: a component the list hides does not
  # exist for the call either.
  def listed(kind, spec, params, ctx) do
    case Middleware.listed(kind, spec, ctx) do
      :ok -> :ok
      {:halt, reason} -> Middleware.refusal(reason, params, ctx)
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
    with {:ok, spec} <- find_tool(server, name, ctx),
         :ok <- visible(spec, name, ctx),
         :ok <- listed(:tools, spec, params, ctx),
         :ok <- allowed(spec, ctx) do
      call_validated(spec, params, ctx)
    end
  end

  def call_tool(_server, _params, _ctx),
    do: {:error, JSONRPC.code(:invalid_params), "tools/call needs a tool name"}

  defp call_validated(%{proxy: proxy} = spec, params, ctx) when proxy != nil do
    raw_args = params["arguments"] || %{}
    with_inputs(spec.name, raw_args, params, ctx, &run_tool(spec, raw_args, &1))
  end

  defp call_validated(spec, params, ctx) do
    raw_args = params["arguments"] || %{}

    case Sake.Schema.validate(spec.input_schema, raw_args) do
      {:ok, args} ->
        with :ok <- task_capability(spec, ctx) do
          with_inputs(spec.name, raw_args, params, ctx, &run_tool(spec, args, &1))
        end

      {:error, errors} ->
        {:ok, Results.tool({:error, "Invalid arguments: " <> format_errors(errors)}, spec, ctx)}
    end
  end

  # A tool that can only run as a task needs a client that takes one.
  defp task_capability(%{task: :required}, ctx) do
    if Tasks.declared?(ctx) or not Sake.Tasks.running?(),
      do: :ok,
      else: Tasks.missing_capability()
  end

  defp task_capability(_spec, _ctx), do: :ok

  defp find_tool(server, name, ctx) do
    case Server.tool(server, name, ctx) do
      {:ok, spec} -> {:ok, spec}
      :error -> {:error, JSONRPC.code(:invalid_params), "Unknown tool: #{name}"}
    end
  end

  # A tool only an app calls does not exist for a client without apps:
  # tools/list leaves it out, and tools/call answers as for an unknown tool.
  defp visible(spec, name, ctx) do
    if UI.visible?(spec, ctx),
      do: :ok,
      else: {:error, JSONRPC.code(:invalid_params), "Unknown tool: #{name}"}
  end

  # A call, a read or a get: the token's scopes, and how its person
  # signed in (`Server.permit/2`).
  defp allowed(spec, ctx), do: Server.permit(spec, ctx)

  # `:before_call` runs on every round of a multi round-trip call, before
  # anything of the tool: what it decides about the arguments is what
  # `prepare/2`, `execute/2` and a task see.
  defp run_tool(spec, args, ctx) do
    case Middleware.before(:before_call, %{tool: spec, arguments: args}, :arguments, ctx) do
      {:ok, args, ctx} -> run_prepared(spec, args, ctx)
      {:halt, reason} -> Middleware.refusal(reason, %{"name" => spec.name}, ctx)
    end
  end

  # An upstream that makes a task of the call has its task followed by one
  # of the proxy's own.
  defp run_prepared(%{proxy: proxy} = spec, args, ctx) when proxy != nil do
    case Forward.call_tool(spec, args, ctx) do
      {:ok, result} -> after_result(result, spec, args, ctx)
      {:task, task} -> follow(spec, task, args, ctx)
      error -> error
    end
  end

  # `prepare/2` runs in the request itself, so it can still ask the client
  # for input on a modern retry before a task takes over the rest. An
  # optional task tool whose caller has no room for another task runs in
  # the request.
  defp run_prepared(spec, args, ctx) do
    case prepare(spec, args, ctx) do
      {:ok, args} ->
        if spec.task && Tasks.declared?(ctx) && Sake.Tasks.running?(),
          do: start_task(spec, args, ctx),
          else: execute(spec, args, ctx)

      {:error, text} ->
        after_call({:error, text}, spec, args, ctx)
    end
  rescue
    exception ->
      if ctx.reraise, do: reraise(exception, __STACKTRACE__)

      Logger.error(
        "tool #{spec.name} failed: " <> Exception.format(:error, exception, __STACKTRACE__)
      )

      after_call({:error, "The tool failed."}, spec, args, ctx)
  end

  # No task of the proxy's own means no one to follow the upstream's: it
  # is cancelled there.
  defp follow(spec, task, args, ctx) do
    case Tasks.start(spec, args, ctx, &Forward.follow(spec, task, &1)) do
      :full ->
        :ok = Forward.cancel_task(spec, task, ctx)
        Tasks.full()

      started ->
        started
    end
  end

  defp start_task(spec, args, ctx) do
    case Tasks.start(spec, args, ctx) do
      :full when spec.task == :optional -> execute(spec, args, ctx)
      :full -> Tasks.full()
      started -> started
    end
  end

  defp execute(spec, args, ctx) do
    case spec.module.execute(args, Mount.component_ctx(spec, ctx)) do
      {:error, {:missing_capability, caps}} -> missing_capability(caps)
      result -> after_call(result, spec, args, ctx)
    end
  end

  # Every result the tool gives the client goes through `:after_call`, an
  # error result too; a task's goes through it when the task ends (see
  # `Sake.Tasks.Worker`).
  defp after_call(value, spec, args, ctx),
    do: value |> Results.tool(spec, ctx) |> after_result(spec, args, ctx)

  defp after_result(result, spec, args, ctx) do
    result = Mount.outer_result(result, spec, ctx)
    payload = %{tool: spec, arguments: args, result: result}

    case Middleware.after_result(:after_call, payload, ctx) do
      {:ok, result} -> {:ok, result}
      {:halt, reason} -> Middleware.refusal(reason, %{"name" => spec.name}, ctx)
    end
  end

  @doc false
  # A component that cannot serve the request without a capability the
  # client did not declare says so with `{:error, {:missing_capability,
  # capabilities}}`: a -32021 error naming them, not a tool error.
  def missing_capability(caps) do
    {:error, JSONRPC.code(:missing_capability), "Missing required client capability",
     %{"requiredCapabilities" => caps}}
  end

  defp prepare(spec, args, ctx) do
    if Code.ensure_loaded?(spec.module) and function_exported?(spec.module, :prepare, 2),
      do: spec.module.prepare(args, Mount.component_ctx(spec, ctx)),
      else: {:ok, args}
  end

  defp format_errors(errors) do
    Enum.map_join(errors, "; ", fn %{path: path, message: m} ->
      Enum.join(path, ".") <> ": " <> m
    end)
  end

  # ---- resources/read

  @doc false
  def read_resource(server, %{"uri" => uri} = params, ctx) when is_binary(uri) do
    with {:ok, spec, uri_params} <- find_resource(server, uri, ctx),
         :ok <- listed(:resources, spec, params, ctx),
         :ok <- allowed(spec, ctx) do
      with_inputs(uri, %{"uri" => uri}, params, ctx, fn ctx ->
        read_result(spec, uri_params, uri, server, ctx)
      end)
    end
  end

  def read_resource(_server, _params, _ctx),
    do: {:error, JSONRPC.code(:invalid_params), "resources/read needs a uri"}

  defp read_result(spec, uri_params, uri, server, ctx) do
    payload = %{resource: spec, uri: uri, params: uri_params}

    case Middleware.before(:before_read, payload, :params, ctx) do
      {:ok, uri_params, ctx} -> read_spec(spec, uri_params, uri, server, ctx)
      {:halt, reason} -> Middleware.refusal(reason, %{"uri" => uri}, ctx)
    end
  end

  # A result that read middleware rewrote or redacted may be one
  # principal's, so it is private. A mounted resource reads as its server
  # knows it, and its contents go out under the mount's prefix.
  defp read_spec(%{proxy: proxy} = spec, uri_params, uri, server, ctx) when proxy != nil do
    case Forward.read(spec, uri, ctx) do
      {:ok, result, ttl} ->
        result = Mount.outer_result(result, spec, ctx)

        with {:ok, result} <- after_read(result, spec, uri_params, uri, ctx) do
          {:ok,
           result
           |> cacheable(server, ctx, [spec.ttl, ttl])
           |> Map.put("cacheScope", "private")}
        end

      {:error, :not_found} ->
        not_found(uri, ctx)

      error ->
        error
    end
  end

  defp read_spec(spec, uri_params, uri, server, ctx) do
    {:ok, inner} = Mount.inner_uri(spec, uri)
    value = spec.module.read(uri_params, Mount.component_ctx(spec, ctx))

    case Results.resource(value, spec, inner, ctx) do
      {:ok, result} ->
        result = Mount.outer_result(result, spec, ctx)

        with {:ok, result} <- after_read(result, spec, uri_params, uri, ctx) do
          {:ok,
           result
           |> cacheable(server, ctx, [spec.ttl])
           |> Middleware.cache_scope(server, [:before_read, :after_read])}
        end

      {:error, :not_found} ->
        not_found(uri, ctx)

      {:error, {:missing_capability, caps}} ->
        missing_capability(caps)

      {:error, text} ->
        {:error, JSONRPC.code(:internal), text}
    end
  end

  defp after_read(result, spec, uri_params, uri, ctx) do
    payload = %{resource: spec, uri: uri, params: uri_params, result: result}

    case Middleware.after_result(:after_read, payload, ctx) do
      {:ok, result} -> {:ok, result}
      {:halt, reason} -> Middleware.refusal(reason, %{"uri" => uri}, ctx)
    end
  end

  defp find_resource(server, uri, ctx) do
    case Server.resource(server, uri, ctx) do
      {:ok, spec, params} ->
        {:ok, spec, params}

      :error ->
        {:error, JSONRPC.code(:invalid_params), "Resource not found: #{uri}", %{"uri" => uri}}
    end
  end

  # The error names the URI in `data`, as both eras' specifications
  # recommend, so a client reading several resources can tell which one
  # was missing.
  @doc false
  def not_found(uri, ctx),
    do: {:error, not_found_code(ctx), "Resource not found: #{uri}", %{"uri" => uri}}

  defp not_found_code(%Context{era: :legacy}), do: JSONRPC.code(:legacy_resource_not_found)
  defp not_found_code(_), do: JSONRPC.code(:invalid_params)

  # ---- prompts/get

  @doc false
  def get_prompt(server, %{"name" => name} = params, ctx) when is_binary(name) do
    with {:ok, spec} <- find_prompt(server, name, ctx),
         :ok <- listed(:prompts, spec, params, ctx),
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
    case Middleware.before(:before_get, %{prompt: spec, arguments: args}, :arguments, ctx) do
      {:ok, args, ctx} -> render_prompt(spec, args, ctx)
      {:halt, reason} -> Middleware.refusal(reason, %{"name" => spec.name}, ctx)
    end
  end

  defp render_prompt(%{proxy: proxy} = spec, args, ctx) when proxy != nil do
    with {:ok, result} <- Forward.get_prompt(spec, args, ctx),
         do: after_get(result, spec, args, ctx)
  end

  defp render_prompt(spec, args, ctx) do
    case Results.prompt(spec.module.get(args, Mount.component_ctx(spec, ctx)), spec, ctx) do
      {:ok, result} -> after_get(result, spec, args, ctx)
      {:error, {:missing_capability, caps}} -> missing_capability(caps)
      {:error, text} -> {:error, JSONRPC.code(:invalid_params), text}
    end
  end

  defp after_get(result, spec, args, ctx) do
    case Middleware.after_result(
           :after_get,
           %{prompt: spec, arguments: args, result: result},
           ctx
         ) do
      {:ok, result} -> {:ok, result}
      {:halt, reason} -> Middleware.refusal(reason, %{"name" => spec.name}, ctx)
    end
  end

  defp find_prompt(server, name, ctx) do
    case Server.prompt(server, name, ctx) do
      {:ok, spec} -> {:ok, spec}
      :error -> {:error, JSONRPC.code(:invalid_params), "Unknown prompt: #{name}"}
    end
  end

  # A proxied prompt's arguments go upstream as the client sent them: only
  # their shape is checked here, and no name becomes an atom.
  defp prompt_args(%{proxy: proxy}, given) when proxy != nil do
    if is_map(given) and Enum.all?(given, fn {_name, value} -> is_binary(value) end),
      do: {:ok, given},
      else: {:error, JSONRPC.code(:invalid_params), "Prompt arguments must be strings"}
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
  # and prompts/get: a component's elicitation, sampling or roots call
  # (`Sake.Server.Ask`) throws to unwind here, and the resulting
  # `requestState` is verified on the next round-trip.

  defp with_inputs(name, args, params, ctx, fun) do
    case resolve_inputs(name, args, params, ctx) do
      :error ->
        {:error, JSONRPC.code(:invalid_params), "Invalid request state"}

      {:ok, inputs} ->
        run_with_inputs(name, args, ctx, inputs, fun)
    end
  end

  # A key under Sake's own prefix is state Sake signed (a proxied call's
  # upstream state, say), never a client's answer.
  defp resolve_inputs(name, args, %{"requestState" => state} = params, ctx) do
    case Sake.Server.RequestState.verify(ctx, name, args, state) do
      {:ok, previous} -> {:ok, Map.merge(previous, answers(params["inputResponses"]))}
      :error -> :error
    end
  end

  # `inputResponses` are only ever honoured alongside the signed
  # `requestState` that proves Sake asked for them; on its own it would let
  # any client inject forged elicitation answers on the first call. Without
  # the state they are ignored, not refused: the handler runs as if nothing
  # had been answered and asks again, which is what the specification
  # recommends when a retry lacks the information the server needs.
  defp resolve_inputs(_name, _args, _params, _ctx), do: {:ok, %{}}

  defp answers(%{} = responses),
    do: Map.reject(responses, fn {key, _} -> String.starts_with?(key, "ai.hattori.sake/") end)

  defp answers(_responses), do: %{}

  defp run_with_inputs(name, args, ctx, inputs, fun) do
    ctx = %{ctx | inputs: inputs}

    try do
      fun.(ctx)
    catch
      :throw, {:sake_input_required, requests} ->
        input_required(ctx, name, args, requests, inputs)

      # A proxied call's questions carry the upstream's state, which the
      # signed request state keeps until the retry.
      :throw, {:sake_input_required, requests, state} ->
        input_required(ctx, name, args, requests, Map.merge(inputs, state))
    end
  end

  defp input_required(ctx, name, args, requests, inputs) do
    {:ok,
     %{
       "resultType" => "input_required",
       "inputRequests" => requests,
       "requestState" => Sake.Server.RequestState.sign(ctx, name, args, inputs)
     }}
  end

  # ---- completion/complete

  @doc false
  def complete(
        server,
        %{"ref" => ref, "argument" => %{"name" => arg, "value" => value}} = params,
        ctx
      ) do
    case resolve_completion_ref(server, ref, ctx) do
      %{module: _} = spec -> listed_completion(spec, arg, value, params, ctx)
      _ -> {:error, JSONRPC.code(:invalid_params), "Unknown completion reference"}
    end
  end

  def complete(_server, _params, _ctx),
    do: {:error, JSONRPC.code(:invalid_params), "completion/complete needs a ref and an argument"}

  defp resolve_completion_ref(server, %{"type" => "ref/prompt", "name" => name}, ctx) do
    with({:ok, s} <- Server.prompt(server, name, ctx), do: s)
  end

  defp resolve_completion_ref(server, %{"type" => "ref/resource", "uri" => uri}, ctx),
    do: Enum.find(Server.resources(server, ctx), &(&1.uri == uri))

  defp resolve_completion_ref(_server, _ref, _ctx), do: :error

  # A prompt or resource template the list hides cannot be completed.
  defp listed_completion(spec, arg, value, params, ctx) do
    kind = if match?(%Sake.Prompt.Spec{}, spec), do: :prompts, else: :resources

    with :ok <- listed(kind, spec, params, ctx) do
      run_completion(spec, arg, value, ctx)
    end
  end

  defp run_completion(spec, arg, value, ctx) do
    cond do
      not Server.allowed?(spec, ctx) -> {:forbidden, spec.scopes}
      spec.proxy != nil -> Forward.complete(spec, arg, value, ctx)
      not completable?(spec.module) -> {:ok, completion([], [])}
      true -> complete_with(spec.module, arg, value, Mount.component_ctx(spec, ctx))
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
        if(ctx.token == nil and ctx.conn_assigns[:sake_auth] in [nil, false],
          do: :public,
          else: :private
        )

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
