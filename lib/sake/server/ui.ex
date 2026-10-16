defmodule Sake.Server.UI do
  @moduledoc false
  # MCP Apps (`Sake.UI`) on the list and call paths of both eras. What a
  # client sees depends on whether it renders apps (`Sake.UI.supported?/1`,
  # from its per-request capabilities on the modern protocol and from its
  # `initialize` on a legacy session): a host gets each tool's `_meta.ui`,
  # every tool and the UI resources; any other client gets the tools as
  # plain tools, without the ones only an app calls, and no UI resources.

  alias Sake.UI

  @default_visibility [:model, :app]

  @doc """
  Adds the extension to the server's `extensions` when it has a UI, or a
  proxy, whose upstream's apps it passes on.
  """
  @spec extensions(map(), module()) :: map()
  def extensions(ext, server) do
    if Sake.Server.dynamic?(server) or Enum.any?(server.__sake__(:resources), & &1.ui),
      do: Map.put_new(ext, UI.extension(), %{}),
      else: ext
  end

  @doc """
  The legacy `initialize` capabilities: a handshake-era host declares MCP
  Apps in its `initialize`, and looks for the server's answer there.
  """
  @spec advertise(map(), module()) :: map()
  def advertise(caps, server) do
    case extensions(%{}, server) do
      ext when ext == %{} -> caps
      ext -> Map.update(caps, "extensions", ext, &Map.merge(&1, ext))
    end
  end

  @doc "Whether the client may see, and call, the tool."
  @spec visible?(Sake.Tool.Spec.t(), Sake.Context.t()) :: boolean()
  def visible?(%{visibility: visibility}, ctx), do: :model in visibility or UI.supported?(ctx)

  @doc "The tool's wire definition, with its `_meta.ui` for a host."
  @spec tool_to_wire(Sake.Tool.Spec.t(), Sake.Context.t()) :: map()
  def tool_to_wire(spec, ctx) do
    wire = Sake.Tool.Spec.to_wire(spec, ctx.protocol_version)

    case UI.supported?(ctx) && tool_meta(spec) do
      meta when is_map(meta) -> Map.put(wire, "_meta", Map.merge(wire["_meta"] || %{}, meta))
      _ -> wire
    end
  end

  # The flat `ui/resourceUri` key is the extension's deprecated spelling;
  # it goes along with `ui.resourceUri`, as the official SDK sends it, for
  # the hosts that read only that one until it is removed.
  defp tool_meta(%{ui: nil, visibility: @default_visibility}), do: nil
  defp tool_meta(%{ui: nil, visibility: v}), do: %{"ui" => %{"visibility" => visibility(v)}}

  defp tool_meta(%{ui: uri, visibility: v}) do
    %{"ui" => %{"resourceUri" => uri, "visibility" => visibility(v)}, "ui/resourceUri" => uri}
  end

  defp visibility(visibility), do: Enum.map(visibility, &Atom.to_string/1)

  @doc "Whether `resources/list` lists the resource to the client."
  @spec listed?(Sake.Resource.Spec.t(), Sake.Context.t()) :: boolean()
  def listed?(%{ui: true}, ctx), do: UI.supported?(ctx)
  def listed?(_spec, _ctx), do: true

  @doc """
  A list that varies with the client's capabilities is private: a shared
  cache would otherwise serve a host the list of a client without apps,
  or the other way around.
  """
  @spec cache_scope(map(), module()) :: map()
  def cache_scope(%{"cacheScope" => _} = result, server) do
    if varies?(server), do: Map.put(result, "cacheScope", "private"), else: result
  end

  def cache_scope(result, _server), do: result

  defp varies?(server) do
    Enum.any?(server.__sake__(:resources), & &1.ui) or
      Enum.any?(server.__sake__(:tools), &(&1.ui != nil or &1.visibility != @default_visibility))
  end
end
