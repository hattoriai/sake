defmodule Sake.Schema do
  @moduledoc """
  Builds JSON Schema 2020-12 from `arg` declarations and validates arguments
  against it.

  The validator covers what the declarations emit: object properties,
  `required`, `additionalProperties`, the primitive types, `enum`, arrays of
  one type, `minimum`/`maximum`, `minLength`/`maxLength`, `pattern`, and
  `default`. It never fetches a `$ref`.
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
    paths = header_paths(schema)

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
  def header_paths(schema), do: header_paths(schema, [], %{})

  defp header_paths(%{"properties" => props}, path, acc) do
    Enum.reduce(props, acc, fn {name, prop}, acc ->
      acc = if h = prop["x-mcp-header"], do: Map.put(acc, h, path ++ [name]), else: acc
      header_paths(prop, path ++ [name], acc)
    end)
  end

  defp header_paths(_, _, acc), do: acc

  @spec valid_header_name?(term()) :: boolean()
  def valid_header_name?(name) when is_binary(name),
    do: name != "" and Regex.match?(@header_name, name)

  def valid_header_name?(_), do: false

  @doc """
  Validates `input` (string or atom keys) against `schema`. Returns the
  arguments with atom keys for declared properties (undeclared properties
  keep their string keys when the schema allows them, so client input never
  creates atoms), defaults applied, and `nil` for absent optional properties.
  """
  @spec validate(map(), map()) ::
          {:ok, map()} | {:error, [%{path: [String.t()], message: String.t()}]}
  def validate(schema, input) when is_map(input) do
    input = Map.new(input, fn {k, v} -> {to_string(k), v} end)

    case check(schema, input, []) do
      {:ok, value} -> {:ok, value}
      {:error, errors} -> {:error, List.flatten(errors)}
    end
  end

  defp check(%{"type" => "object"} = schema, value, path) when is_map(value) do
    props = schema["properties"] || %{}
    required = schema["required"] || []
    additional = Map.get(schema, "additionalProperties", true)

    {results, errors} = process_properties(props, required, value, path, {%{}, []})

    {results, errors} =
      process_extra_properties(
        Map.drop(value, Map.keys(props)),
        additional,
        path,
        {results, errors}
      )

    if errors == [], do: {:ok, results}, else: {:error, Enum.reverse(errors)}
  end

  defp check(%{"type" => "object"}, _value, path),
    do: {:error, %{path: path, message: "must be an object"}}

  defp check(%{"type" => "array", "items" => items}, value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce({[], []}, fn {v, i}, {acc, errs} ->
      case check(items, v, path ++ [Integer.to_string(i)]) do
        {:ok, v} -> {[v | acc], errs}
        {:error, e} -> {acc, [e | errs]}
      end
    end)
    |> case do
      {acc, []} -> {:ok, Enum.reverse(acc)}
      {_, errs} -> {:error, Enum.reverse(errs)}
    end
  end

  defp check(%{"type" => "array"}, _value, path),
    do: {:error, %{path: path, message: "must be an array"}}

  defp check(%{"enum" => values} = schema, value, path) do
    if value in values,
      do: check(Map.delete(schema, "enum"), value, path),
      else: {:error, %{path: path, message: "must be one of #{Enum.join(values, ", ")}"}}
  end

  defp check(%{"type" => "string"} = s, value, path) when is_binary(value) do
    cond do
      s["minLength"] && String.length(value) < s["minLength"] ->
        {:error, %{path: path, message: "must be at least #{s["minLength"]} characters"}}

      s["maxLength"] && String.length(value) > s["maxLength"] ->
        {:error, %{path: path, message: "must be at most #{s["maxLength"]} characters"}}

      s["pattern"] && not Regex.match?(Regex.compile!(s["pattern"]), value) ->
        {:error, %{path: path, message: "does not match #{s["pattern"]}"}}

      true ->
        {:ok, value}
    end
  end

  defp check(%{"type" => "string"}, _value, path),
    do: {:error, %{path: path, message: "must be a string"}}

  defp check(%{"type" => "integer"} = s, value, path) when is_float(value) do
    if Float.floor(value) == value,
      do: check(s, trunc(value), path),
      else: {:error, %{path: path, message: "must be an integer"}}
  end

  defp check(%{"type" => "integer"} = s, value, path) when is_integer(value),
    do: range(s, value, path)

  defp check(%{"type" => "integer"}, _value, path),
    do: {:error, %{path: path, message: "must be an integer"}}

  defp check(%{"type" => "number"} = s, value, path) when is_number(value),
    do: range(s, value, path)

  defp check(%{"type" => "number"}, _value, path),
    do: {:error, %{path: path, message: "must be a number"}}

  defp check(%{"type" => "boolean"}, value, _path) when is_boolean(value), do: {:ok, value}

  defp check(%{"type" => "boolean"}, _value, path),
    do: {:error, %{path: path, message: "must be a boolean"}}

  defp check(_schema, value, _path), do: {:ok, value}

  defp process_properties(props, required, value, path, acc) do
    Enum.reduce(props, acc, fn {name, prop}, {results, errors} ->
      # Declared property names come from the host's schema, not from the client; undeclared keys stay strings.
      key = String.to_atom(name)

      case Map.fetch(value, name) do
        {:ok, v} ->
          validate_and_update(key, prop, v, path ++ [name], results, errors)

        :error ->
          handle_missing_property(name, prop, key, path, required, results, errors)
      end
    end)
  end

  defp validate_and_update(key, prop, value, path, results, errors) do
    case check(prop, value, path) do
      {:ok, v} -> {Map.put(results, key, v), errors}
      {:error, e} -> {results, [e | errors]}
    end
  end

  defp handle_missing_property(name, prop, key, path, required, results, errors) do
    cond do
      name in required -> {results, [%{path: path ++ [name], message: "is required"} | errors]}
      Map.has_key?(prop, "default") -> {Map.put(results, key, prop["default"]), errors}
      true -> {Map.put(results, key, nil), errors}
    end
  end

  defp process_extra_properties(extra, additional, path, {results, errors}) do
    cond do
      extra == %{} ->
        {results, errors}

      additional == false ->
        {results,
         Enum.map(extra, fn {k, _} ->
           %{path: path ++ [k], message: "is not an accepted argument"}
         end) ++
           errors}

      true ->
        {Map.merge(results, extra), errors}
    end
  end

  defp range(s, value, path) do
    cond do
      s["minimum"] && value < s["minimum"] ->
        {:error, %{path: path, message: "must be at least #{s["minimum"]}"}}

      s["maximum"] && value > s["maximum"] ->
        {:error, %{path: path, message: "must be at most #{s["maximum"]}"}}

      true ->
        {:ok, value}
    end
  end
end
