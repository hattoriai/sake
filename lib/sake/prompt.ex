defmodule Sake.Prompt do
  @moduledoc """
  A prompt template: `arg` lines (strings only) and `get/2`, which returns
  messages as `{:user | :assistant, text | %Sake.Content{}}`.
  """

  @callback spec() :: Sake.Prompt.Spec.t()
  @callback get(args :: map(), ctx :: Sake.Context.t()) ::
              {:ok, [{atom(), term()}]}
              | {:ok, [{atom(), term()}], keyword()}
              | {:error, String.t()}
              | {:error, {:missing_capability, map()}}
  @callback complete(arg :: String.t(), partial :: String.t(), ctx :: Sake.Context.t()) ::
              {:ok, [String.t()]} | {:ok, [String.t()], keyword()}
  @optional_callbacks complete: 3

  defmodule Spec do
    @moduledoc "The compiled definition of a prompt."
    @type t :: %__MODULE__{}
    defstruct [
      :module,
      :name,
      :title,
      :description,
      :meta,
      icons: [],
      scopes: [],
      args: [],
      ttl: nil
    ]

    @spec to_wire(t(), String.t()) :: map()
    def to_wire(%__MODULE__{} = s, revision) do
      %{"name" => s.name}
      |> maybe_put("title", if(revision >= "2025-06-18", do: s.title))
      |> maybe_put("description", s.description)
      |> maybe_put("icons", if(revision >= "2025-11-25", do: Sake.Tool.icons_to_wire(s.icons)))
      |> maybe_put("arguments", Enum.map(s.args, &arg_to_wire/1))
      |> maybe_put("_meta", s.meta)
    end

    defp arg_to_wire(a),
      do: %{"name" => a.name, "required" => a.required} |> maybe_put("description", a.description)

    defp maybe_put(m, _k, nil), do: m
    defp maybe_put(m, _k, []), do: m
    defp maybe_put(m, k, v), do: Map.put(m, k, v)
  end

  defmacro __using__(opts) do
    quote do
      @behaviour Sake.Prompt
      @sake_opts unquote(opts)
      Module.register_attribute(__MODULE__, :sake_args, accumulate: true)
      import Sake.Prompt, only: [arg: 2, arg: 3]
      @before_compile Sake.Prompt
    end
  end

  defmacro arg(name, type, opts \\ []) do
    quote do
      @sake_args {unquote(name), unquote(type), unquote(opts)}
    end
  end

  defmacro __before_compile__(env) do
    opts = Module.get_attribute(env.module, :sake_opts)
    args = env.module |> Module.get_attribute(:sake_args) |> Enum.reverse()

    for {name, type, _} <- args,
        type != :string,
        do:
          raise(
            ArgumentError,
            "#{inspect(env.module)}: prompt arguments are strings; #{name} is #{inspect(type)}"
          )

    spec = %Spec{
      module: env.module,
      name: opts[:name] || Sake.Tool.default_name(env.module),
      title: opts[:title],
      description: opts[:description],
      icons: opts[:icons] || [],
      scopes: List.wrap(opts[:scope]),
      args:
        Enum.map(args, fn {n, _t, o} ->
          %{name: to_string(n), description: o[:description], required: o[:required] || false}
        end),
      ttl: opts[:ttl],
      meta: opts[:meta]
    }

    quote do
      @impl Sake.Prompt
      def spec, do: unquote(Macro.escape(spec))
    end
  end
end
