defmodule Sake.Schema do
  @moduledoc """
  Builds JSON Schema 2020-12 from `arg` declarations and validates arguments
  against it.

  Validation is JSON Schema 2020-12 (`Sake.Schema.Validator`): what the
  declarations emit, and the rest of the dialect a tool's own
  `input_schema:` may use, local `$ref`s, composition and conditions
  included. It never fetches a remote `$ref`.
  """

  @type arg :: {atom(), type(), keyword()}
  @type type ::
          :string
          | :integer
          | :number
          | :boolean
          | :any
          | {:array, type()}
          | {:enum, [term()]}
          | {:object, [arg()]}

  @header_name ~r/^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/

  @spec build([arg()]) :: map()
  def build([]), do: %{"type" => "object", "additionalProperties" => false}

  def build(args) when is_list(args) do
    schema = object(args)
    check_headers!(schema)
    schema
  end

  defp object(args) do
    properties =
      Map.new(args, fn {name, type, opts} -> {to_string(name), property(type, opts)} end)

    required = for {name, _type, opts} <- args, opts[:required], do: to_string(name)

    %{"type" => "object", "properties" => properties, "additionalProperties" => false}
    |> then(fn s -> if required == [], do: s, else: Map.put(s, "required", required) end)
  end

  defp property(type, opts) do
    base(type)
    |> put_opt("description", opts[:description])
    |> put_opt("default", opts[:default])
    |> put_opt("minimum", opts[:min])
    |> put_opt("maximum", opts[:max])
    |> put_opt("minLength", opts[:min_length])
    |> put_opt("maxLength", opts[:max_length])
    |> put_opt("pattern", opts[:pattern])
    |> put_opt("format", opts[:format])
    |> put_opt("x-mcp-header", opts[:header])
  end

  defp base(:string), do: %{"type" => "string"}
  defp base(:integer), do: %{"type" => "integer"}
  defp base(:number), do: %{"type" => "number"}
  defp base(:boolean), do: %{"type" => "boolean"}
  defp base(:any), do: %{}
  defp base({:array, type}), do: %{"type" => "array", "items" => base(type)}
  defp base({:enum, values}), do: %{"type" => "string", "enum" => values}
  defp base({:object, args}), do: object(args)

  defp put_opt(map, _key, nil), do: map
  defp put_opt(map, key, value), do: Map.put(map, key, value)

  defp check_headers!(schema) do
    paths = header_entries(schema)

    for {name, path} <- paths do
      prop = get_in(schema, Enum.flat_map(path, &["properties", &1]))

      unless valid_header_name?(name),
        do:
          raise(
            ArgumentError,
            "invalid x-mcp-header name #{inspect(name)} on #{Enum.join(path, ".")}"
          )

      unless prop["type"] in ["string", "integer", "boolean"],
        do:
          raise(
            ArgumentError,
            "x-mcp-header on #{Enum.join(path, ".")} needs a string, integer or boolean argument"
          )
    end

    names = Enum.map(paths, fn {n, _} -> String.downcase(n) end)

    if length(Enum.uniq(names)) != length(names),
      do: raise(ArgumentError, "x-mcp-header names must be unique ignoring case")

    :ok
  end

  @doc "Header name → property path for every `x-mcp-header` reachable through `properties` only."
  @spec header_paths(map()) :: %{String.t() => [String.t()]}
  def header_paths(schema), do: schema |> header_entries() |> Map.new()

  @doc """
  Every `x-mcp-header` reachable through `properties` only, as `{name,
  path}` pairs. Unlike `header_paths/1`, a name used twice appears twice,
  so a check for duplicates sees it.
  """
  @spec header_entries(map()) :: [{String.t(), [String.t()]}]
  def header_entries(schema), do: schema |> header_entries([], []) |> Enum.reverse()

  defp header_entries(%{"properties" => props}, path, acc) when is_map(props) do
    Enum.reduce(props, acc, fn {name, prop}, acc ->
      header = is_map(prop) && prop["x-mcp-header"]
      acc = if header, do: [{header, path ++ [name]} | acc], else: acc

      header_entries(prop, path ++ [name], acc)
    end)
  end

  defp header_entries(_, _, acc), do: acc

  @spec valid_header_name?(term()) :: boolean()
  def valid_header_name?(name) when is_binary(name),
    do: name != "" and Regex.match?(@header_name, name)

  def valid_header_name?(_), do: false

  @doc """
  Validates `input` (string or atom keys) against `schema` with
  `Sake.Schema.Validator`, which implements JSON Schema 2020-12 (local
  references, composition, conditions and the rest; see its
  documentation). Returns the arguments with atom keys for the properties
  `properties` declares (undeclared properties keep their string keys,
  so client input never creates atoms), defaults applied, and `nil` for
  absent optional properties. A whole number sent where an integer is
  expected (`2.0`) becomes one (`2`).

  With `absent: :omit`, an absent optional property with no default is left
  out instead, at every level (objects in arrays too): the arguments are
  what the client sent, and a tool tells a property the client left out
  from one it sent as `null`.
  """
  @spec validate(map(), map(), keyword()) ::
          {:ok, map()} | {:error, [%{path: [String.t()], message: String.t()}]}
  def validate(schema, input, opts \\ []) when is_map(input) do
    input = Map.new(input, fn {k, v} -> {to_string(k), v} end)

    case Sake.Schema.Validator.validate(schema, input) do
      :ok ->
        value = shape(schema, input)

        if Keyword.get(opts, :absent, nil) == :omit,
          do: {:ok, omit_absent(schema, value, input)},
          else: {:ok, value}

      {:error, errors} ->
        {:error, errors}
    end
  end

  # The validated value without the declared properties the input did not
  # have (and that have no default), level by level along the schema.
  defp omit_absent(%{"type" => "object"} = schema, value, input)
       when is_map(value) and is_map(input) do
    input = Map.new(input, fn {k, v} -> {to_string(k), v} end)

    Enum.reduce(schema["properties"] || %{}, value, fn {name, prop}, acc ->
      omit_property(acc, String.to_atom(name), prop, Map.fetch(input, name))
    end)
  end

  defp omit_absent(%{"type" => "array", "items" => items}, value, input)
       when is_list(value) and is_list(input) and length(value) == length(input),
       do: value |> Enum.zip(input) |> Enum.map(fn {v, given} -> omit_absent(items, v, given) end)

  defp omit_absent(_schema, value, _input), do: value

  defp omit_property(acc, key, prop, {:ok, given}),
    do: Map.update!(acc, key, &omit_absent(prop, &1, given))

  defp omit_property(acc, key, prop, :error),
    do: if(Map.has_key?(prop, "default"), do: acc, else: Map.delete(acc, key))

  # The arguments a tool receives, from input the validator accepted:
  # declared properties under atom keys (the names come from the host's
  # schema, never from the client), defaults and `nil` for absent ones,
  # whole numbers as integers where the schema says `integer`.
  defp shape(%{"type" => "object"} = schema, value) when is_map(value) do
    props = if is_map(schema["properties"]), do: schema["properties"], else: %{}

    declared =
      Map.new(props, fn {name, prop} ->
        key = String.to_atom(name)

        case Map.fetch(value, name) do
          {:ok, v} -> {key, shape(prop, v)}
          :error -> {key, if(is_map(prop), do: Map.get(prop, "default"))}
        end
      end)

    value |> Map.drop(Map.keys(props)) |> Map.merge(declared)
  end

  defp shape(%{"type" => "array", "items" => items}, value) when is_list(value),
    do: Enum.map(value, &shape(items, &1))

  defp shape(%{"type" => "integer"}, value) when is_float(value), do: trunc(value)
  defp shape(_schema, value), do: value
end
