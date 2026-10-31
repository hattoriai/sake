defmodule Sake.Server.Extensions do
  @moduledoc false
  # The extensions a server serves (`Sake.Extension`): the ones it and the
  # servers it mounts list, and the ones Sake implements itself on top of
  # the same machinery (skills, when the server has any). Checked when the
  # server compiles; advertised in `server/discover` and `initialize`;
  # their methods dispatched when no core method matches.

  require Logger

  alias Sake.{Context, JSONRPC, Server}
  alias Sake.Extension.{Method, Spec}
  alias Sake.Server.Dispatch

  # Methods the protocol, and Sake on top of it, serve or send: no
  # extension may take one.
  @core ~w(initialize ping server/discover logging/setLevel completion/complete
           tools/list tools/call resources/list resources/templates/list resources/read
           resources/subscribe resources/unsubscribe resources/directory/read
           prompts/list prompts/get subscriptions/listen
           tasks/get tasks/update tasks/cancel tasks/list tasks/result
           skills/list skills/get sampling/createMessage elicitation/create roots/list)

  @doc "The methods no extension may declare."
  @spec core() :: [String.t()]
  def core, do: @core

  # ---- compiling

  @doc """
  The server's extensions, then each mounted server's (an extension two of
  them list is served once, by the first), checked together.
  """
  @spec compile!(module(), [module()], [{module(), keyword()}], term(), map() | nil) :: [Spec.t()]
  def compile!(server, modules, mounts, required, advertised) do
    own = Enum.map(modules, &own_spec!(server, &1, required))

    mounted =
      for {mounted, opts} <- mounts,
          spec <- mounted.__sake__(:extension_specs),
          do: mount(spec, mounted, opts, required, server)

    specs = Enum.uniq_by(own ++ mounted, & &1.module)
    check!(server, specs, advertised || %{})
    specs
  end

  defp own_spec!(server, module, required) do
    Code.ensure_compiled!(module)

    if not function_exported?(module, :__sake_extension__, 0) do
      raise ArgumentError,
            "#{inspect(server)}: extensions takes Sake.Extension modules, got #{inspect(module)}"
    end

    spec = module.__sake_extension__()
    where = "#{inspect(server)}: #{inspect(module)}"

    %{
      spec
      | methods:
          Enum.map(spec.methods, fn m ->
            %{
              m
              | authentication: Sake.Auth.Authentication.merge!(m.authentication, required, where)
            }
          end)
    }
  end

  # A mounted server's extension: the mount's scopes and the parent's
  # authentication on every method, as on its tools.
  defp mount(spec, mounted, opts, required, server) do
    where = "#{inspect(server)}: #{inspect(spec.module)}"

    methods =
      Enum.map(spec.methods, fn m ->
        %{
          m
          | scopes: Enum.uniq(m.scopes ++ (opts[:scopes] || [])),
            authentication: Sake.Auth.Authentication.merge!(m.authentication, required, where)
        }
      end)

    %{spec | methods: methods, mount: spec.mount ++ [{mounted, opts}]}
  end

  defp check!(server, specs, advertised) do
    specs
    |> Enum.group_by(& &1.id)
    |> Enum.each(fn
      {_id, [_]} ->
        :ok

      {id, [a, b | _]} ->
        raise ArgumentError,
              "#{inspect(server)}: #{inspect(a.module)} and #{inspect(b.module)} are both the extension #{inspect(id)}"
    end)

    for spec <- specs, Map.has_key?(advertised, spec.id) do
      raise ArgumentError,
            "#{inspect(server)}: the extension #{inspect(spec.id)} is both in extensions: and served by #{inspect(spec.module)}"
    end

    methods = for spec <- specs, method <- spec.methods, do: {method.name, spec.module}

    for {name, module} <- methods do
      cond do
        name in @core ->
          raise ArgumentError,
                "#{inspect(server)}: #{inspect(module)} declares #{inspect(name)}, a method of the protocol"

        String.starts_with?(name, "notifications/") ->
          raise ArgumentError,
                "#{inspect(server)}: #{inspect(module)} declares #{inspect(name)} as a method; notifications/ names a notification"

        true ->
          :ok
      end
    end

    methods
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.each(fn
      {_name, [_]} ->
        :ok

      {name, [a, b | _]} ->
        raise ArgumentError,
              "#{inspect(server)}: #{inspect(a)} and #{inspect(b)} both declare the method #{inspect(name)}"
    end)
  end

  # ---- serving

  @doc "The extensions the server serves: listed ones, then Sake's own."
  @spec specs(module()) :: [Spec.t()]
  def specs(server) do
    listed = server.__sake__(:extension_specs)
    if Server.skills?(server), do: listed ++ [skills()], else: listed
  end

  # Skills (`Sake.Skill`) are an extension Sake serves through the same
  # dispatch as a listed one: `Sake.Server.Skills` answers its methods.
  defp skills do
    id = Sake.Skill.extension()

    %Spec{
      id: id,
      module: Sake.Server.Skills,
      methods:
        for(
          name <- ["skills/list", "skills/get", "resources/directory/read"],
          do: %Method{name: name, module: Sake.Server.Skills, id: id}
        )
    }
  end

  defp served?(%Spec{since: nil}, _ctx), do: true
  defp served?(%Spec{since: since}, %Context{protocol_version: revision}), do: revision >= since

  @doc "The extensions the request's revision is served, with their settings."
  @spec advertised(module(), Context.t()) :: map()
  def advertised(server, ctx) do
    for spec <- specs(server), served?(spec, ctx), into: %{} do
      {spec.id, settings(spec, server)}
    end
  end

  @doc "The legacy `initialize` capabilities, with the extensions."
  @spec advertise(map(), module(), Context.t()) :: map()
  def advertise(caps, server, ctx) do
    case advertised(server, ctx) do
      ext when ext == %{} -> caps
      ext -> Map.update(caps, "extensions", ext, &Map.merge(&1, ext))
    end
  end

  defp settings(%Spec{module: module} = spec, server) do
    if Code.ensure_loaded?(module) and function_exported?(module, :settings, 1),
      do: module.settings(own_server(spec, server)),
      else: %{}
  end

  defp own_server(%Spec{mount: [{server, _opts} | _]}, _server), do: server
  defp own_server(_spec, server), do: server

  @doc "The identifiers of the server's extensions that send notifications."
  @spec notifying(module()) :: [String.t()]
  def notifying(server), do: for(%{notifications: [_ | _]} = s <- specs(server), do: s.id)

  @doc """
  Answers an extension method, or, when no extension the request's
  revision is served has it, `-32601` as for any unknown method.
  """
  @spec handle(module(), String.t(), map(), Context.t()) :: term()
  def handle(server, method, params, ctx) do
    with {:ok, spec, m} <- find(server, method, ctx),
         :ok <- negotiated(spec, ctx),
         :ok <- Server.permit(m, ctx) do
      run(spec, m, params, ctx)
    end
  end

  defp find(server, name, ctx) do
    Enum.find_value(
      specs(server),
      {:error, JSONRPC.code(:method_not_found), "Method not found"},
      fn spec ->
        with true <- served?(spec, ctx),
             %Method{} = m <- Enum.find(spec.methods, &(&1.name == name)) do
          {:ok, spec, m}
        else
          _ -> nil
        end
      end
    )
  end

  defp negotiated(%Spec{client: :required, id: id}, ctx) do
    if Sake.Extension.declared?(ctx, id),
      do: :ok,
      else: Dispatch.missing_capability(%{"extensions" => %{id => %{}}})
  end

  defp negotiated(_spec, _ctx), do: :ok

  defp run(spec, m, params, ctx) do
    params = if is_map(params), do: params, else: %{}

    spec
    |> extension_ctx(ctx)
    |> then(&spec.module.handle(m.name, params, &1))
    |> result(spec, ctx)
  rescue
    exception ->
      if ctx.reraise, do: reraise(exception, __STACKTRACE__)

      Logger.error(
        "extension #{spec.id} failed on #{m.name}: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      {:error, JSONRPC.code(:internal), "The request failed."}
  end

  # The context the extension runs with: its own server's, with the
  # prefixes of the mounts between it and the request's.
  defp extension_ctx(%Spec{mount: []}, ctx), do: ctx

  defp extension_ctx(%Spec{mount: [{server, _} | _] = chain}, ctx) do
    %{
      ctx
      | server: server,
        prefixes: Enum.map(chain, fn {_server, opts} -> opts[:prefix] end) ++ ctx.prefixes
    }
  end

  defp result({:ok, %{} = result}, spec, ctx) do
    case result["resultType"] do
      nil -> {:ok, result}
      "complete" -> {:ok, result}
      type -> result_type(type, result, spec, ctx)
    end
  end

  defp result({:error, code, message}, _spec, _ctx) when is_integer(code) and is_binary(message),
    do: {:error, code, message}

  defp result({:error, code, message, data}, _spec, _ctx)
       when is_integer(code) and is_binary(message),
       do: {:error, code, message, data}

  defp result({:error, {:missing_capability, caps}}, _spec, _ctx) when is_map(caps),
    do: Dispatch.missing_capability(caps)

  # A refusal by the same checks a core method makes (`Server.permit/2`,
  # the `:after_list` plugs), which the extension may run itself.
  defp result({:forbidden, scopes} = refusal, _spec, _ctx) when is_list(scopes), do: refusal

  defp result({:insufficient_user_authentication, %{}} = refusal, _spec, _ctx), do: refusal

  defp result(other, spec, _ctx) do
    Logger.error("extension #{spec.id} returned #{inspect(other)}, not a result")
    {:error, JSONRPC.code(:internal), "The request failed."}
  end

  # A result type of the extension's own goes only to a client that
  # negotiated the extension, which is the only one that can read it.
  defp result_type(type, result, spec, ctx) do
    if type in spec.result_types and Sake.Extension.declared?(ctx, spec.id) do
      {:ok, result}
    else
      Logger.error(
        "extension #{spec.id} returned the result type #{inspect(type)}, " <>
          "which it does not declare or the client did not negotiate"
      )

      {:error, JSONRPC.code(:internal), "The request failed."}
    end
  end
end
