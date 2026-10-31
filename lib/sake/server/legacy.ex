defmodule Sake.Server.Legacy do
  @moduledoc false
  # The handshake-era methods (revisions 2025-03-26 to 2025-11-25).

  alias Sake.{Context, JSONRPC, Protocol, Server}
  alias Sake.Server.{Dispatch, Skills, UI}

  @type outcome ::
          Dispatch.outcome()
          | {:initialize, String.t(), map(), map()}
          | {:subscribe, String.t()}
          | {:unsubscribe, String.t()}

  @spec handle(module(), JSONRPC.parsed(), Context.t()) :: outcome()
  def handle(_server, {:notification, _method, _params}, _ctx), do: :noreply

  def handle(server, {:request, _id, "initialize", params}, ctx) do
    case params do
      %{"protocolVersion" => requested, "capabilities" => caps}
      when is_binary(requested) and is_map(caps) ->
        revision = Protocol.negotiate_legacy(requested)
        info = server.__sake__(:info)

        result =
          %{
            "protocolVersion" => revision,
            "capabilities" =>
              server
              |> Server.capabilities()
              |> UI.advertise(server)
              |> Skills.advertise(server)
              |> advertise_auth(ctx),
            "serverInfo" => %{"name" => info.name, "version" => info.version}
          }
          |> then(
            &if(i = server.__sake__(:instructions), do: Map.put(&1, "instructions", i), else: &1)
          )

        {:initialize, revision, caps, result}

      _ ->
        {:error,
         error(JSONRPC.code(:invalid_params), "initialize needs protocolVersion and capabilities")}
    end
  end

  def handle(server, {:request, id, method, params}, ctx) do
    ctx = %{ctx | request_id: id, method: method, server: server, era: :legacy}

    case Dispatch.request(server, method, params, ctx, &dispatch/4) do
      {:ok, result} -> {:reply, result}
      {:error, code, message} -> {:error, error(code, message)}
      {:error, code, message, data} -> {:error, Map.put(error(code, message), "data", data)}
      other -> other
    end
  end

  # The endpoint's authorization extensions, in the `initialize` result
  # as MCP Apps are (see `Dispatch.auth_extensions/1`).
  defp advertise_auth(caps, ctx) do
    case Dispatch.auth_extensions(ctx) do
      ext when ext == %{} -> caps
      ext -> Map.update(caps, "extensions", ext, &Map.merge(ext, &1))
    end
  end

  defp dispatch(_server, "ping", _params, _ctx), do: {:ok, %{}}

  defp dispatch(_server, "logging/setLevel", params, _ctx) do
    if Sake.Progress.level?(params["level"]),
      do: {:ok, %{}},
      else: {:error, JSONRPC.code(:invalid_params), "Unknown log level"}
  end

  defp dispatch(server, "tools/list", params, ctx), do: Dispatch.list_tools(server, params, ctx)
  defp dispatch(server, "tools/call", params, ctx), do: Dispatch.call_tool(server, params, ctx)

  defp dispatch(server, "resources/list", params, ctx),
    do: Dispatch.list_resources(server, params, ctx)

  defp dispatch(server, "resources/templates/list", params, ctx),
    do: Dispatch.list_resource_templates(server, params, ctx)

  defp dispatch(server, "resources/read", params, ctx),
    do: Dispatch.read_resource(server, params, ctx)

  defp dispatch(server, "prompts/list", params, ctx),
    do: Dispatch.list_prompts(server, params, ctx)

  defp dispatch(server, "prompts/get", params, ctx), do: Dispatch.get_prompt(server, params, ctx)

  defp dispatch(server, "completion/complete", params, ctx),
    do: Dispatch.complete(server, params, ctx)

  defp dispatch(server, "skills/list", params, ctx), do: Dispatch.skills(server, params, ctx)
  defp dispatch(server, "skills/get", params, ctx), do: Dispatch.skill(server, params, ctx)

  defp dispatch(server, "resources/directory/read", params, ctx),
    do: Dispatch.read_directory(server, params, ctx)

  defp dispatch(server, "resources/subscribe", %{"uri" => uri}, ctx) when is_binary(uri) do
    case Server.resource(server, uri, ctx) do
      {:ok, %{subscribe: true} = spec, _} ->
        with :ok <- Dispatch.listed(:resources, spec, %{"uri" => uri}, ctx),
             do: subscribe(spec, uri, ctx)

      _ ->
        {:error, JSONRPC.code(:invalid_params), "Resource does not support subscriptions: #{uri}"}
    end
  end

  defp dispatch(_server, "resources/unsubscribe", %{"uri" => uri}, _ctx) when is_binary(uri),
    do: {:unsubscribe, uri}

  defp dispatch(_server, _method, _params, _ctx),
    do: {:error, JSONRPC.code(:method_not_found), "Method not found"}

  # A resource the server's middleware hides is answered by `dispatch/4` as one
  # without subscriptions; the scopes are checked after.
  # A proxied resource is followed upstream (see `Sake.Proxy`).
  defp subscribe(spec, uri, ctx) do
    if Server.allowed?(spec, ctx) do
      if spec.proxy, do: :ok = Sake.Proxy.follow(spec, uri)
      {:subscribe, uri}
    else
      {:forbidden, spec.scopes}
    end
  end

  defp error(code, message), do: %{"code" => code, "message" => message}
end
