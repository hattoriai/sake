defmodule Sake.UI do
  @moduledoc """
  An MCP App: an HTML document the host renders in a sandboxed iframe when
  a tool that links it is called (the `io.modelcontextprotocol/ui`
  extension). On the wire it is a resource with a `ui://` URI and the
  `text/html;profile=mcp-app` MIME type, so it is listed on a server with
  the other resources:

      defmodule MyApp.MCP.SalesMap do
        use Sake.UI,
          uri: "ui://my-app/sales-map",
          name: "sales_map",
          title: "Sales map",
          csp: [resource_domains: ["https://tile.openstreetmap.org"]],
          prefers_border: true

        @impl true
        def render(_ctx), do: ~s(<!doctype html><html>...</html>)
      end

      defmodule MyApp.MCP do
        use Sake.Server, name: "my-app", version: "1.0.0"
        tools [MyApp.MCP.ShowSales]
        resources [MyApp.MCP.SalesMap]
      end

  A tool shows it with `use Sake.Tool, ui: MyApp.MCP.SalesMap`.

  Options: `uri` (required, `ui://`), `name` (default: the module's last
  segment in snake case), `title`, `description`, `icons`, `scope`, `ttl`,
  `meta`, `csp` (`connect_domains`, `resource_domains`, `frame_domains`,
  `base_uri_domains`: the origins the document may reach), `permissions`
  (`:camera`, `:microphone`, `:geolocation`, `:clipboard_write`), `domain`
  (a dedicated sandbox origin, in the host's own format), `prefers_border`,
  and `template`.

  The document comes from `render/1`, which returns a string or iodata,
  `{:safe, iodata}`, or, when the host has `phoenix_html`, anything that
  implements `Phoenix.HTML.Safe` (the result of a HEEx function
  component), or from an EEx file named by `template:`,
  relative to the module's own file and compiled into the module. A
  template's assigns come from `assigns/1`, and `<%= %>` escapes its
  output as HTML unless the value is `raw/1`. `inline/1` reads a file into
  the document at compile time (a bundled script or stylesheet), and the
  module recompiles when the file or the template changes.

  The host learns the document's CSP and permissions from the resource's
  `_meta.ui`, on its `resources/list` entry and on its `resources/read`
  contents alike. A client that did not declare the extension does not
  see UI resources listed (it can still read them).
  """

  @mime_type "text/html;profile=mcp-app"
  @extension "io.modelcontextprotocol/ui"

  @csp [
    connect_domains: "connectDomains",
    resource_domains: "resourceDomains",
    frame_domains: "frameDomains",
    base_uri_domains: "baseUriDomains"
  ]

  @permissions [
    camera: "camera",
    microphone: "microphone",
    geolocation: "geolocation",
    clipboard_write: "clipboardWrite"
  ]

  @doc "The HTML document of the app."
  @callback render(ctx :: Sake.Context.t()) :: iodata() | {:safe, iodata()} | struct()

  @doc "The assigns of a `template:`, as a map or a keyword list."
  @callback assigns(ctx :: Sake.Context.t()) :: map() | keyword()

  @optional_callbacks render: 1, assigns: 1

  @doc "The MIME type of an MCP App document."
  @spec mime_type() :: String.t()
  def mime_type, do: @mime_type

  @doc "The identifier of the MCP Apps extension."
  @spec extension() :: String.t()
  def extension, do: @extension

  @doc """
  Whether the client renders MCP Apps: it declared the extension, with the
  `text/html;profile=mcp-app` MIME type among its `mimeTypes`. A tool can
  use it to word its text for a client that shows no UI.
  """
  @spec supported?(Sake.Context.t()) :: boolean()
  def supported?(%Sake.Context{client_capabilities: caps}) do
    case caps do
      %{"extensions" => %{@extension => %{"mimeTypes" => types}}} when is_list(types) ->
        @mime_type in types

      _ ->
        false
    end
  end

  @doc """
  The client capability a host declares to render MCP Apps (the one
  `Sake.Client.connect/2` declares with `ui: true`).
  """
  @spec client_capability() :: map()
  def client_capability, do: %{@extension => %{"mimeTypes" => [@mime_type]}}

  @doc """
  The contents of `path`, relative to the project's root, read at compile
  time: the module recompiles when the file changes. For the bundled
  script or stylesheet of the app, so that the document is
  self-contained.

      <script><%= raw inline("priv/static/assets/sales_map.js") %></script>
  """
  defmacro inline(path) when is_binary(path) do
    path = Path.expand(path)
    if __CALLER__.module, do: Module.put_attribute(__CALLER__.module, :external_resource, path)
    File.read!(path)
  end

  @doc "Marks `iodata` as HTML that a template must not escape."
  @spec raw(iodata() | {:safe, iodata()}) :: {:safe, iodata()}
  def raw({:safe, _} = safe), do: safe
  def raw(iodata), do: {:safe, iodata}

  @doc "Escapes a value for an HTML document; `{:safe, iodata}` passes through."
  @spec escape(term()) :: String.t()
  def escape({:safe, iodata}), do: IO.iodata_to_binary(iodata)
  def escape(nil), do: ""
  def escape(value) when is_binary(value), do: Plug.HTML.html_escape(value)
  def escape(list) when is_list(list), do: Enum.map_join(list, &escape_item/1)

  # A struct the host renders with Phoenix.HTML (a HEEx component's
  # result, a date) is escaped the way Phoenix escapes it.
  if Code.ensure_loaded?(Phoenix.HTML.Safe) do
    def escape(%_{} = struct),
      do: struct |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
  end

  def escape(value), do: value |> to_string() |> Plug.HTML.html_escape()

  # A list is iodata, as the result of a `for` in a template is: its
  # integers are characters, not numbers.
  defp escape_item(char) when is_integer(char), do: escape(<<char::utf8>>)
  defp escape_item(item), do: escape(item)

  @doc false
  def document({:safe, iodata}), do: IO.iodata_to_binary(iodata)

  def document(iodata) when is_binary(iodata) or is_list(iodata),
    do: IO.iodata_to_binary(iodata)

  # What `render/1` returns is the document, not text to escape: only
  # what is neither iodata nor `{:safe, iodata}` (a HEEx component's
  # `%Phoenix.LiveView.Rendered{}`) goes through Phoenix.HTML.
  if Code.ensure_loaded?(Phoenix.HTML.Safe) do
    def document(content), do: content |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
  end

  @doc false
  # The `@name` of a template.
  def fetch_assign!(assigns, key) do
    case Access.fetch(assigns, key) do
      {:ok, value} ->
        value

      :error ->
        raise ArgumentError, "assign @#{key} not available in the template of an MCP App"
    end
  end

  defmacro __using__(opts) do
    quote do
      @behaviour Sake.Resource
      @behaviour Sake.UI
      @sake_opts unquote(opts)
      import Sake.UI, only: [inline: 1, raw: 1]
      @before_compile Sake.UI
    end
  end

  defmacro __before_compile__(env) do
    opts = Module.get_attribute(env.module, :sake_opts)
    spec = build_spec(env.module, opts)

    quote do
      @impl Sake.Resource
      def spec, do: unquote(Macro.escape(spec))

      @impl Sake.Resource
      def read(_params, ctx), do: {:ok, Sake.UI.document(render(ctx))}

      unquote(template(env, opts[:template]))
    end
  end

  defp build_spec(module, opts) do
    %Sake.Resource.Spec{
      module: module,
      uri: uri!(module, opts[:uri]),
      name: opts[:name] || Sake.Tool.default_name(module),
      title: opts[:title],
      description: opts[:description],
      mime_type: @mime_type,
      icons: opts[:icons] || [],
      scopes: List.wrap(opts[:scope]),
      ttl: opts[:ttl],
      meta: meta(module, opts),
      ui: true
    }
  end

  defp uri!(module, "ui://" <> _ = uri) do
    if String.contains?(uri, "{"),
      do: raise(ArgumentError, "#{inspect(module)}: a UI has a fixed uri, not a template"),
      else: uri
  end

  defp uri!(module, uri),
    do: raise(ArgumentError, "#{inspect(module)}: a UI needs a ui:// uri, got #{inspect(uri)}")

  # The resource's `_meta`: the host reads `_meta.ui` both on the listed
  # resource (to review it before any tool runs) and on the read contents.
  defp meta(module, opts) do
    ui =
      %{}
      |> put_some("csp", csp(module, opts[:csp] || []))
      |> put_some("permissions", permissions(module, opts[:permissions] || []))
      |> put_some("domain", opts[:domain])
      |> put_some("prefersBorder", opts[:prefers_border])

    meta = opts[:meta] || %{}
    meta = if ui == %{}, do: meta, else: Map.put(meta, "ui", ui)
    if meta == %{}, do: nil, else: meta
  end

  defp csp(_module, []), do: nil

  defp csp(module, csp) do
    Map.new(csp, fn {key, domains} ->
      case Keyword.fetch(@csp, key) do
        {:ok, name} when is_list(domains) -> {name, domains}
        _ -> raise ArgumentError, "#{inspect(module)}: unknown csp entry #{inspect(key)}"
      end
    end)
  end

  defp permissions(_module, []), do: nil

  defp permissions(module, permissions) do
    Map.new(permissions, fn permission ->
      case Keyword.fetch(@permissions, permission) do
        {:ok, name} ->
          {name, %{}}

        :error ->
          raise ArgumentError, "#{inspect(module)}: unknown permission #{inspect(permission)}"
      end
    end)
  end

  defp put_some(map, _key, nil), do: map
  defp put_some(map, key, value), do: Map.put(map, key, value)

  # A `template:` is compiled into `render/1` here, in Sake, so that the
  # host's module needs nothing from EEx at run time.
  defp template(env, nil) do
    unless Module.defines?(env.module, {:render, 1}),
      do: raise(ArgumentError, "#{inspect(env.module)}: a UI needs render/1 or a template:")
  end

  defp template(env, path) do
    if Module.defines?(env.module, {:render, 1}),
      do:
        raise(ArgumentError, "#{inspect(env.module)}: a UI has render/1 or a template:, not both")

    path = Path.expand(path, Path.dirname(env.file))
    compiled = EEx.compile_file(path, engine: Sake.UI.Engine, file: path, line: 1)

    assigns =
      if Module.defines?(env.module, {:assigns, 1}),
        do: quote(do: assigns(ctx)),
        else: quote(do: %{})

    quote do
      @external_resource unquote(path)

      @impl Sake.UI
      def render(ctx), do: __sake_template__(unquote(assigns))

      # A template without assigns leaves `assigns` unused.
      defp __sake_template__(var!(assigns)) do
        _ = var!(assigns)
        unquote(compiled)
      end
    end
  end
end
