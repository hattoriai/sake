defmodule Sake.Resource do
  @moduledoc """
  A resource: a fixed `uri:` or a template with `{name}` placeholders, and
  `read/2`. A template resource may implement `list/1` to enumerate concrete
  resources. `subscribe: true` lets clients subscribe to updates, which the
  host announces with `Sake.Server.resource_updated/2`.
  """

  @callback spec() :: Sake.Resource.Spec.t()
  @callback read(params :: map(), ctx :: Sake.Context.t()) ::
              {:ok, term()}
              | {:error, :not_found}
              | {:error, String.t()}
              | {:error, {:missing_capability, map()}}
  @callback list(ctx :: Sake.Context.t()) :: [String.t() | map()]
  @callback complete(arg :: String.t(), partial :: String.t(), ctx :: Sake.Context.t()) ::
              {:ok, [String.t()]} | {:ok, [String.t()], keyword()}
  @optional_callbacks list: 1, complete: 3

  defmodule Spec do
    @moduledoc "The compiled definition of a resource."
    @type t :: %__MODULE__{}
    defstruct [
      :module,
      :uri,
      :name,
      :title,
      :description,
      :mime_type,
      :meta,
      :regex,
      :params,
      template: false,
      icons: [],
      scopes: [],
      subscribe: false,
      annotations: %{},
      ttl: nil,
      ui: false
    ]

    @spec match(t(), String.t()) :: {:ok, map()} | :error
    def match(%__MODULE__{template: false, uri: uri}, uri), do: {:ok, %{}}
    def match(%__MODULE__{template: false}, _), do: :error

    def match(%__MODULE__{regex: regex, params: params}, uri) do
      case Regex.run(regex, uri, capture: :all_but_first) do
        nil -> :error
        values -> {:ok, params |> Enum.zip(values) |> Map.new()}
      end
    end

    @spec to_wire(t(), String.t()) :: map()
    def to_wire(%__MODULE__{} = s, revision), do: entry(s, "uri", s.uri, revision)

    @spec template_to_wire(t(), String.t()) :: map()
    def template_to_wire(%__MODULE__{} = s, revision),
      do: entry(s, "uriTemplate", s.uri, revision)

    @doc "The wire entry of a concrete resource produced by `list/1`."
    @spec listed_to_wire(t(), String.t() | map(), String.t()) :: map()
    def listed_to_wire(s, uri, revision) when is_binary(uri), do: entry(s, "uri", uri, revision)

    def listed_to_wire(s, %{uri: uri} = item, revision) do
      s = %{
        s
        | name: item[:name] || s.name,
          title: item[:title] || s.title,
          description: item[:description] || s.description,
          mime_type: item[:mime_type] || s.mime_type
      }

      entry(s, "uri", uri, revision)
    end

    defp entry(s, key, value, revision) do
      %{key => value, "name" => s.name}
      |> maybe_put("title", if(revision >= "2025-06-18", do: s.title))
      |> maybe_put("description", s.description)
      |> maybe_put("mimeType", s.mime_type)
      |> maybe_put("icons", if(revision >= "2025-11-25", do: Sake.Tool.icons_to_wire(s.icons)))
      |> maybe_put(
        "annotations",
        Sake.Content.to_wire(Sake.Content.text("", annotations: s.annotations))["annotations"]
      )
      |> maybe_put("_meta", s.meta)
    end

    defp maybe_put(m, _k, nil), do: m
    defp maybe_put(m, _k, []), do: m
    defp maybe_put(m, k, v), do: Map.put(m, k, v)
  end

  defmacro __using__(opts) do
    quote do
      @behaviour Sake.Resource
      @sake_opts unquote(opts)
      @before_compile Sake.Resource
    end
  end

  defmacro __before_compile__(env) do
    opts = Module.get_attribute(env.module, :sake_opts)
    uri = opts[:uri] || raise(ArgumentError, "#{inspect(env.module)}: a resource needs a uri")

    params =
      ~r/\{([a-zA-Z_][a-zA-Z0-9_]*)\}/
      |> Regex.scan(uri, capture: :all_but_first)
      |> List.flatten()
      |> Enum.map(&String.to_atom/1)

    template = params != []

    regex_source =
      if template do
        source =
          uri
          |> Regex.escape()
          |> String.replace(~r/\\\{[a-zA-Z_][a-zA-Z0-9_]*\\\}/, "([^/]+)")

        "^" <> source <> "$"
      end

    spec = %Spec{
      module: env.module,
      uri: uri,
      template: template,
      regex: regex_source && Regex.compile!(regex_source),
      params: params,
      name: opts[:name] || Sake.Tool.default_name(env.module),
      title: opts[:title],
      description: opts[:description],
      mime_type: opts[:mime_type],
      icons: opts[:icons] || [],
      scopes: List.wrap(opts[:scope]),
      subscribe: opts[:subscribe] || false,
      annotations: Map.new(opts[:annotations] || []),
      ttl: opts[:ttl],
      meta: opts[:meta]
    }

    quote do
      @impl Sake.Resource
      def spec, do: unquote(Macro.escape(spec))
    end
  end
end
