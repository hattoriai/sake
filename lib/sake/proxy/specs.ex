defmodule Sake.Proxy.Specs do
  @moduledoc false
  # An upstream's tools, resources and prompts as specs of the proxy.
  # What an upstream sends is untrusted: an entry that is not shaped as
  # its kind is left out, names must be what Sake itself accepts, nothing
  # an upstream sends becomes an atom, and the proxy's configuration
  # (`only`/`except`, `scope`, `scopes`) decides what is listed and what it
  # requires. Each spec names its proxy in `proxy`, and has no module:
  # `Sake.Server.Dispatch` forwards its calls.

  alias Sake.{Prompt, Resource, Tool}

  @tool_name ~r/^[A-Za-z0-9_.\-]{1,128}$/
  @max_entries 1_000
  @max_name 256

  @spec build(module(), atom(), term(), keyword()) :: [struct()]
  def build(proxy, :tools, entries, config) do
    for entry <- Enum.take(entries, @max_entries),
        spec = tool(entry),
        spec != nil,
        allowed?(config[:tools], spec.name),
        do: %{spec | proxy: proxy, scopes: scopes(config, spec.name)}
  end

  def build(proxy, :prompts, entries, config) do
    for entry <- Enum.take(entries, @max_entries),
        spec = prompt(entry),
        spec != nil,
        allowed?(config[:prompts], spec.name),
        do: %{spec | proxy: proxy, scopes: scopes(config, spec.name)}
  end

  def build(proxy, :resources, %{resources: resources, templates: templates}, config) do
    listed =
      for entry <- Enum.take(resources, @max_entries),
          spec = resource(entry),
          spec != nil,
          do: spec

    templated =
      for entry <- Enum.take(templates, @max_entries),
          spec = template(entry),
          spec != nil,
          do: spec

    (listed ++ templated)
    |> Enum.uniq_by(& &1.uri)
    |> Enum.map(&%{&1 | proxy: proxy, scopes: config[:scope]})
  end

  @doc "A resource the upstream does not list, for a URI the proxy was asked to read."
  @spec unlisted(module(), String.t(), keyword()) :: Resource.Spec.t()
  def unlisted(proxy, uri, config) do
    %Resource.Spec{
      uri: uri,
      name: uri,
      proxy: proxy,
      scopes: config[:scope],
      subscribe: Sake.Proxy.Watcher.subscribe?(proxy)
    }
  end

  defp allowed?(false, _name), do: false
  defp allowed?(true, _name), do: true
  defp allowed?(nil, _name), do: true

  defp allowed?(filter, name) when is_list(filter) do
    cond do
      only = filter[:only] -> name in only
      except = filter[:except] -> name not in except
      true -> true
    end
  end

  defp scopes(config, name),
    do: Enum.uniq(config[:scope] ++ List.wrap(Map.get(config[:scopes], name)))

  # ---- tools

  defp tool(%{"name" => name} = entry) when is_binary(name) do
    with true <- Regex.match?(@tool_name, name),
         %Tool.Spec{} = spec <-
           Sake.Client.tool_spec(Map.put(entry, "inputSchema", input_schema(entry))) do
      %{
        spec
        | title: string(entry["title"]),
          description: string(entry["description"]),
          output_schema: map(entry["outputSchema"]),
          annotations: tool_annotations(entry["annotations"]),
          icons: icons(entry["icons"]),
          meta: tool_meta(entry["_meta"]),
          ui: ui_uri(spec.ui)
      }
    else
      _ -> nil
    end
  end

  defp tool(_entry), do: nil

  defp input_schema(%{"inputSchema" => %{"type" => "object"} = schema}), do: schema
  defp input_schema(_entry), do: %{"type" => "object"}

  @hints %{
    "readOnlyHint" => :read_only,
    "destructiveHint" => :destructive,
    "idempotentHint" => :idempotent,
    "openWorldHint" => :open_world
  }

  defp tool_annotations(%{} = annotations) do
    hints =
      for {key, value} <- annotations,
          Map.has_key?(@hints, key),
          into: %{},
          do: {@hints[key], value == true}

    put_some(hints, :title, string(annotations["title"]))
  end

  defp tool_annotations(_annotations), do: %{}

  # A tool's MCP App travels in `ui` and `visibility`, which Sake sends
  # in `_meta` itself (and only to a client that renders apps).
  defp tool_meta(%{} = meta) do
    case Map.drop(meta, ["ui", "ui/resourceUri", Sake.Protocol.meta(:server_info)]) do
      empty when empty == %{} -> nil
      meta -> meta
    end
  end

  defp tool_meta(_meta), do: nil

  defp ui_uri("ui://" <> _ = uri), do: uri
  defp ui_uri(_uri), do: nil

  # ---- prompts

  defp prompt(%{"name" => name} = entry) when is_binary(name) do
    if name?(name) do
      %Prompt.Spec{
        name: name,
        title: string(entry["title"]),
        description: string(entry["description"]),
        icons: icons(entry["icons"]),
        meta: map(entry["_meta"]),
        args: prompt_args(entry["arguments"])
      }
    end
  end

  defp prompt(_entry), do: nil

  defp prompt_args(args) when is_list(args) do
    for %{"name" => name} = arg <- args, is_binary(name) and name?(name) do
      %{name: name, description: string(arg["description"]), required: arg["required"] == true}
    end
  end

  defp prompt_args(_args), do: []

  # ---- resources

  defp resource(%{"uri" => uri} = entry) when is_binary(uri) do
    if uri?(uri) do
      entry
      |> resource_fields()
      |> Map.merge(%{uri: uri, name: string(entry["name"]) || uri})
      |> then(&struct(Resource.Spec, &1))
    end
  end

  defp resource(_entry), do: nil

  # A template's URIs match it with any value in a `{name}` (one segment)
  # or in the expressions of RFC 6570's other operators (anything): the
  # upstream decides what it serves.
  defp template(%{"uriTemplate" => uri} = entry) when is_binary(uri) do
    if uri?(uri) do
      entry
      |> resource_fields()
      |> Map.merge(%{
        uri: uri,
        name: string(entry["name"]) || uri,
        template: true,
        params: [],
        regex: pattern(uri)
      })
      |> then(&struct(Resource.Spec, &1))
    end
  end

  defp template(_entry), do: nil

  defp pattern(uri) do
    source =
      ~r/\{([^}]*)\}/
      |> Regex.split(uri, include_captures: true)
      |> Enum.map_join(fn
        "{" <> expression -> if simple?(expression), do: "([^/]+)", else: "(.*)"
        literal -> Regex.escape(literal)
      end)

    Regex.compile!("^" <> source <> "$")
  end

  defp simple?(expression), do: Regex.match?(~r/^[A-Za-z0-9_.%]+\}$/, expression)

  defp resource_fields(entry) do
    mime_type = string(entry["mimeType"])

    %{
      title: string(entry["title"]),
      description: string(entry["description"]),
      mime_type: mime_type,
      icons: icons(entry["icons"]),
      annotations: resource_annotations(entry["annotations"]),
      meta: map(entry["_meta"]),
      ui: mime_type == Sake.UI.mime_type()
    }
  end

  defp resource_annotations(%{} = annotations) do
    %{}
    |> put_some(:audience, audience(annotations["audience"]))
    |> put_some(:priority, if(is_number(annotations["priority"]), do: annotations["priority"]))
    |> put_some(:last_modified, string(annotations["lastModified"]))
  end

  defp resource_annotations(_annotations), do: %{}

  defp audience(list) when is_list(list) do
    case for(a <- list, a in ["user", "assistant"], do: String.to_existing_atom(a)) do
      [] -> nil
      audience -> audience
    end
  end

  defp audience(_list), do: nil

  # ---- shared

  defp icons(icons) when is_list(icons) do
    for %{"src" => src} = icon <- icons, is_binary(src) do
      %{src: src}
      |> put_some(:mime_type, string(icon["mimeType"]))
      |> put_some(
        :sizes,
        if(is_list(icon["sizes"]), do: Enum.filter(icon["sizes"], &is_binary/1))
      )
      |> put_some(:theme, string(icon["theme"]))
    end
  end

  defp icons(_icons), do: []

  defp name?(name), do: byte_size(name) in 1..@max_name and String.printable?(name)

  defp uri?(uri),
    do: byte_size(uri) <= 2_048 and String.printable?(uri) and String.contains?(uri, ":")

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: nil

  defp map(%{} = value), do: value
  defp map(_value), do: nil

  defp put_some(map, _key, nil), do: map
  defp put_some(map, key, value), do: Map.put(map, key, value)
end
