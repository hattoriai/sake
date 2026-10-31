defmodule Sake.Schema.Validator do
  @moduledoc """
  A JSON Schema 2020-12 validator, for the schemas tools publish: what
  `arg` lines build, and a tool's own `input_schema:` and `output_schema:`.

  It implements the core, applicator, unevaluated and validation
  vocabularies of draft 2020-12:

    * references: `$ref` to the schema itself (`#`), to a JSON Pointer in
      it (`#/$defs/address`), to an `$anchor` (`#addressDef`), and to a
      schema embedded with its own `$id`, relative or absolute;
    * composition and conditions: `allOf`, `anyOf`, `oneOf`, `not`,
      `if`/`then`/`else`, `dependentSchemas`, `dependentRequired`;
    * objects: `properties`, `patternProperties`, `additionalProperties`,
      `unevaluatedProperties`, `propertyNames`, `required`,
      `minProperties`, `maxProperties`;
    * arrays: `prefixItems`, `items`, `contains` (with `minContains` and
      `maxContains`), `unevaluatedItems`, `minItems`, `maxItems`,
      `uniqueItems`;
    * values: `type` (one or a list), `enum`, `const`, `multipleOf`,
      `minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`,
      `minLength`, `maxLength` (in code points), `pattern`;
    * boolean schemas (`true`, `false`).

  `format`, `title`, `description`, `default`, `examples`, `deprecated`,
  `readOnly`, `writeOnly`, the `content*` keywords and unknown keywords
  (`x-mcp-header`, say) are annotations: they do not fail a value.
  `pattern` and `patternProperties` are compiled with Erlang's PCRE in
  Unicode mode, which reads the ECMA-262 patterns schemas use alike for
  everything but a few escapes.

  What it refuses, rather than validating less than the schema says (see
  `check_schema/1`): another dialect in `$schema` (draft 2020-12 is the
  MCP default, and the only one), `$dynamicRef` and `$recursiveRef`, and
  a `$ref` it cannot resolve within the schema. It never fetches a
  remote reference. Its work is bounded: a reference may nest 64 deep,
  and one validation evaluates at most 100 000 schemas; past either, the
  value is refused. A schema of more than 100 000 schemas is refused
  outright.
  """

  @dialect "https://json-schema.org/draft/2020-12/schema"
  @dialects [@dialect, @dialect <> "#"]
  @base "sake:///schema"
  @max_depth 64
  @max_steps 100_000

  @typedoc "A failed validation: where, and why."
  @type error :: %{path: [String.t()], message: String.t()}

  defmodule State do
    @moduledoc false
    defstruct [:index, :base, depth: 0, steps: 0]
  end

  @doc "The JSON Schema dialect validated: draft 2020-12."
  @spec dialect() :: String.t()
  def dialect, do: @dialect

  @doc """
  Whether Sake can validate against `schema`: its `$schema`, if any, is
  draft 2020-12; it uses no `$dynamicRef` or `$recursiveRef`; each of its
  `$ref`s resolves within it; and each `pattern` compiles.
  """
  @spec check_schema(term()) :: :ok | {:error, String.t()}
  def check_schema(schema) when is_boolean(schema), do: :ok

  def check_schema(schema) when is_map(schema) do
    with :ok <- check_dialect(schema),
         {:ok, index} <- index(schema) do
      check_node(schema, index, base(schema, @base), [])
    end
  end

  def check_schema(other), do: {:error, "a schema is a map or a boolean, got #{inspect(other)}"}

  defp check_dialect(%{"$schema" => dialect}) when dialect in @dialects, do: :ok

  defp check_dialect(%{"$schema" => dialect}),
    do:
      {:error,
       "the dialect #{inspect(dialect)} is not supported; Sake validates JSON Schema 2020-12 (#{@dialect})"}

  defp check_dialect(_schema), do: :ok

  defp check_node(schema, index, base, path) when is_map(schema) do
    base = base(schema, base)

    case problem(schema, index, base) do
      nil -> check_subschemas(schema, index, base, path)
      message -> {:error, "#{pointer(path)}: #{message}"}
    end
  end

  defp check_node(_schema, _index, _base, _path), do: :ok

  defp check_subschemas(schema, index, base, path) do
    schema
    |> subschemas(path)
    |> Enum.reduce_while(:ok, fn {sub, sub_path}, :ok ->
      case check_node(sub, index, base, sub_path) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # What keeps Sake from validating against a schema node, if anything.
  defp problem(schema, index, base) do
    cond do
      Map.has_key?(schema, "$dynamicRef") or Map.has_key?(schema, "$recursiveRef") ->
        "$dynamicRef and $recursiveRef are not supported"

      is_binary(schema["$ref"]) and resolve(schema["$ref"], index, base) == :error ->
        "the $ref #{inspect(schema["$ref"])} does not resolve within the schema"

      is_binary(schema["pattern"]) and regex(schema["pattern"]) == :error ->
        "the pattern #{inspect(schema["pattern"])} does not compile"

      true ->
        nil
    end
  end

  @single ~w(additionalProperties unevaluatedProperties propertyNames items contains
             unevaluatedItems not if then else)
  @lists ~w(allOf anyOf oneOf prefixItems)
  @maps ~w($defs definitions properties patternProperties dependentSchemas)

  # The schemas inside a schema, with their paths: what the applicators
  # apply, and the definitions a reference may name.
  defp subschemas(schema, path) do
    singles = for key <- @single, sub = schema[key], is_map(sub), do: {sub, path ++ [key]}

    lists =
      for key <- @lists,
          list = schema[key],
          is_list(list),
          {sub, i} <- Enum.with_index(list),
          is_map(sub),
          do: {sub, path ++ [key, Integer.to_string(i)]}

    maps =
      for key <- @maps,
          map = schema[key],
          is_map(map),
          {name, sub} <- map,
          is_map(sub),
          do: {sub, path ++ [key, name]}

    singles ++ lists ++ maps
  end

  # ---- validation

  @doc """
  Validates `value` (JSON, with string keys) against `schema`. Every
  error is returned, each with the path of the value that failed, in the
  order of their paths.
  """
  @spec validate(map() | boolean(), term()) :: :ok | {:error, [error()]}
  def validate(schema, value) do
    with :ok <- check_dialect(if(is_map(schema), do: schema, else: %{})),
         {:ok, index} <- index(schema) do
      state = %State{index: index, base: base(schema, @base)}

      case eval(schema, value, [], state) do
        {[], _evaluated, _state} -> :ok
        {errors, _evaluated, _state} -> {:error, Enum.sort_by(errors, & &1.path)}
      end
    else
      {:error, message} -> {:error, [%{path: [], message: message}]}
    end
  catch
    {:sake_schema_limit, message} -> {:error, [%{path: [], message: message}]}
  end

  # A schema's evaluation: its errors, what it evaluated of the value (for
  # `unevaluatedProperties` and `unevaluatedItems`), and the state.
  defp eval(true, _value, _path, state), do: {[], none(), state}
  defp eval(false, _value, path, state), do: {[error(path, "is not allowed")], none(), state}

  defp eval(schema, value, path, state) when is_map(schema) do
    state = step(state)
    outer_base = state.base
    state = %{state | base: base(schema, state.base)}

    {errors, evaluated, state} =
      case assertions(schema, value, path) do
        {:stop, errors} ->
          {errors, none(), state}

        {:cont, errors} ->
          {more, evaluated, state} = applicators(schema, value, path, state)
          {errors ++ more, evaluated, state}
      end

    {errors, evaluated, %{state | base: outer_base}}
  end

  defp eval(_schema, _value, _path, state), do: {[], none(), state}

  defp step(%State{steps: steps}) when steps >= @max_steps,
    do: throw({:sake_schema_limit, "the schema took too much work to validate"})

  defp step(state), do: %{state | steps: state.steps + 1}

  defp none, do: %{props: MapSet.new(), items: MapSet.new()}

  defp merge(a, b) do
    %{props: MapSet.union(a.props, b.props), items: merge_items(a.items, b.items)}
  end

  defp merge_items(:all, _), do: :all
  defp merge_items(_, :all), do: :all
  defp merge_items(a, b), do: MapSet.union(a, b)

  # ---- the assertions on the value itself: type, then enum and const,
  # then the rest. A value of the wrong type, or not among the enum or
  # const, gets that error alone: nothing else of the schema applies to it.

  defp assertions(schema, value, path) do
    cond do
      Map.has_key?(schema, "type") and not type?(schema["type"], value) ->
        {:stop, [error(path, type_message(schema["type"]))]}

      Map.has_key?(schema, "enum") and not member?(schema["enum"], value) ->
        {:stop,
         [
           error(
             path,
             "must be one of #{Enum.map_join(List.wrap(schema["enum"]), ", ", &show/1)}"
           )
         ]}

      Map.has_key?(schema, "const") and not equal?(schema["const"], value) ->
        {:stop, [error(path, "must be #{show(schema["const"])}")]}

      true ->
        {:cont, assertions_on(schema, value, path)}
    end
  end

  defp assertions_on(schema, value, path) do
    string(schema, value, path) ++
      number(schema, value, path) ++
      array_size(schema, value, path) ++ object_size(schema, value, path)
  end

  defp type?(types, value) when is_list(types), do: Enum.any?(types, &type?(&1, value))
  defp type?("object", value), do: is_map(value)
  defp type?("array", value), do: is_list(value)
  defp type?("string", value), do: is_binary(value)
  defp type?("number", value), do: is_number(value)
  defp type?("integer", value) when is_integer(value), do: true
  defp type?("integer", value) when is_float(value), do: Float.floor(value) == value
  defp type?("integer", _value), do: false
  defp type?("boolean", value), do: is_boolean(value)
  defp type?("null", value), do: is_nil(value)
  defp type?(_unknown, _value), do: false

  defp type_message("object"), do: "must be an object"
  defp type_message("array"), do: "must be an array"
  defp type_message("integer"), do: "must be an integer"
  defp type_message("null"), do: "must be null"
  defp type_message(type) when is_binary(type), do: "must be a #{type}"
  defp type_message(types) when is_list(types), do: "must be of type #{Enum.join(types, " or ")}"
  defp type_message(_type), do: "has an unknown type"

  defp member?(values, value) when is_list(values), do: Enum.any?(values, &equal?(&1, value))
  defp member?(_values, _value), do: false

  # JSON equality: 1 and 1.0 are the same number, and objects and arrays
  # compare by their contents.
  defp equal?(a, b) when is_number(a) and is_number(b), do: a == b

  defp equal?(a, b) when is_list(a) and is_list(b),
    do: length(a) == length(b) and Enum.all?(Enum.zip(a, b), fn {x, y} -> equal?(x, y) end)

  defp equal?(a, b) when is_map(a) and is_map(b),
    do:
      map_size(a) == map_size(b) and
        Enum.all?(a, fn {k, v} -> Map.has_key?(b, k) and equal?(v, b[k]) end)

  defp equal?(a, b), do: a === b

  defp show(value) when is_binary(value), do: value
  defp show(value), do: JSON.encode!(value)

  defp string(schema, value, path) when is_binary(value) do
    length = String.length(value)

    [
      if(is_integer(schema["minLength"]) and length < schema["minLength"],
        do: error(path, "must be at least #{schema["minLength"]} characters")
      ),
      if(is_integer(schema["maxLength"]) and length > schema["maxLength"],
        do: error(path, "must be at most #{schema["maxLength"]} characters")
      ),
      if(is_binary(schema["pattern"]) and not matches?(schema["pattern"], value),
        do: error(path, "does not match #{schema["pattern"]}")
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp string(_schema, _value, _path), do: []

  defp number(schema, value, path) when is_number(value) do
    [
      bound(schema["minimum"], &(value < &1), path, "must be at least"),
      bound(schema["maximum"], &(value > &1), path, "must be at most"),
      bound(schema["exclusiveMinimum"], &(value <= &1), path, "must be greater than"),
      bound(schema["exclusiveMaximum"], &(value >= &1), path, "must be less than"),
      multiple(schema["multipleOf"], value, path)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp number(_schema, _value, _path), do: []

  defp bound(limit, fails?, path, message) when is_number(limit) do
    if fails?.(limit), do: error(path, "#{message} #{limit}")
  end

  defp bound(_limit, _fails?, _path, _message), do: nil

  defp multiple(divisor, value, path) when is_number(divisor) and divisor > 0 do
    quotient = value / divisor

    if abs(quotient - Float.round(quotient)) > 1.0e-9,
      do: error(path, "must be a multiple of #{divisor}")
  end

  defp multiple(_divisor, _value, _path), do: nil

  defp array_size(schema, value, path) when is_list(value) do
    count = length(value)

    [
      if(is_integer(schema["minItems"]) and count < schema["minItems"],
        do: error(path, "must have at least #{schema["minItems"]} items")
      ),
      if(is_integer(schema["maxItems"]) and count > schema["maxItems"],
        do: error(path, "must have at most #{schema["maxItems"]} items")
      ),
      if(schema["uniqueItems"] == true and not unique?(value),
        do: error(path, "must not have duplicate items")
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp array_size(_schema, _value, _path), do: []

  defp unique?(list) do
    list
    |> Enum.with_index()
    |> Enum.all?(fn {a, i} -> not Enum.any?(Enum.drop(list, i + 1), &equal?(a, &1)) end)
  end

  defp object_size(schema, value, path) when is_map(value) do
    count = map_size(value)
    required = if is_list(schema["required"]), do: schema["required"], else: []

    missing =
      for name <- required,
          is_binary(name),
          not Map.has_key?(value, name),
          do: error(path ++ [name], "is required")

    dependent =
      for {name, needed} <- schema["dependentRequired"] || %{},
          Map.has_key?(value, name),
          is_list(needed),
          other <- needed,
          not Map.has_key?(value, other),
          do: error(path ++ [other], "is required when #{name} is present")

    sizes =
      [
        if(is_integer(schema["minProperties"]) and count < schema["minProperties"],
          do: error(path, "must have at least #{schema["minProperties"]} properties")
        ),
        if(is_integer(schema["maxProperties"]) and count > schema["maxProperties"],
          do: error(path, "must have at most #{schema["maxProperties"]} properties")
        )
      ]
      |> Enum.reject(&is_nil/1)

    missing ++ dependent ++ sizes
  end

  defp object_size(_schema, _value, _path), do: []

  # ---- the applicators: in-place first (references, composition,
  # conditions), then the value's members, then the unevaluated ones,
  # which need what everything else evaluated.

  defp applicators(schema, value, path, state) do
    {e1, ev1, state} = reference(schema, value, path, state)
    {e2, ev2, state} = composition(schema, value, path, state)
    {e3, ev3, state} = conditional(schema, value, path, state)
    {e4, ev4, state} = members(schema, value, path, state)
    evaluated = ev1 |> merge(ev2) |> merge(ev3) |> merge(ev4)
    {e5, ev5, state} = unevaluated(schema, value, path, evaluated, state)
    {e1 ++ e2 ++ e3 ++ e4 ++ e5, merge(evaluated, ev5), state}
  end

  defp reference(%{"$ref" => ref}, value, path, state) when is_binary(ref) do
    case resolve(ref, state.index, state.base) do
      {:ok, target, target_base} ->
        if state.depth >= @max_depth,
          do: throw({:sake_schema_limit, "the schema's references nest too deep"})

        {errors, evaluated, inner} =
          eval(target, value, path, %{state | base: target_base, depth: state.depth + 1})

        {errors, evaluated, %{state | steps: inner.steps}}

      :error ->
        {[error(path, "the schema's $ref #{inspect(ref)} does not resolve")], none(), state}
    end
  end

  defp reference(_schema, _value, _path, state), do: {[], none(), state}

  defp composition(schema, value, path, state) do
    {e1, ev1, state} = all_of(schema["allOf"], value, path, state)
    {e2, ev2, state} = any_of(schema["anyOf"], value, path, state)
    {e3, ev3, state} = one_of(schema["oneOf"], value, path, state)
    {e4, state} = not_schema(schema, value, path, state)
    {e1 ++ e2 ++ e3 ++ e4, ev1 |> merge(ev2) |> merge(ev3), state}
  end

  defp all_of(list, value, path, state) when is_list(list) do
    Enum.reduce(list, {[], none(), state}, fn sub, {errors, evaluated, state} ->
      {e, ev, state} = eval(sub, value, path, state)
      {errors ++ e, merge(evaluated, ev), state}
    end)
  end

  defp all_of(_list, _value, _path, state), do: {[], none(), state}

  # Every branch is evaluated, the passing ones' annotations kept, as
  # `unevaluated*` needs.
  defp branches(list, value, path, state) do
    Enum.map_reduce(list, state, fn sub, state ->
      {errors, evaluated, state} = eval(sub, value, path, state)
      {{errors, evaluated}, state}
    end)
  end

  defp any_of(list, value, path, state) when is_list(list) and list != [] do
    {results, state} = branches(list, value, path, state)
    passing = for {[], evaluated} <- results, do: evaluated

    if passing == [],
      do: {[error(path, "must match at least one of the schemas in anyOf")], none(), state},
      else: {[], Enum.reduce(passing, none(), &merge/2), state}
  end

  defp any_of(_list, _value, _path, state), do: {[], none(), state}

  defp one_of(list, value, path, state) when is_list(list) and list != [] do
    {results, state} = branches(list, value, path, state)

    case for({[], evaluated} <- results, do: evaluated) do
      [evaluated] ->
        {[], evaluated, state}

      [] ->
        {[error(path, "must match exactly one of the schemas in oneOf, matches none")], none(),
         state}

      many ->
        {[error(path, "must match exactly one of the schemas in oneOf, matches #{length(many)}")],
         none(), state}
    end
  end

  defp one_of(_list, _value, _path, state), do: {[], none(), state}

  defp not_schema(%{"not" => sub}, value, path, state) do
    case eval(sub, value, path, state) do
      {[], _evaluated, state} -> {[error(path, "must not match the schema in not")], state}
      {_errors, _evaluated, state} -> {[], state}
    end
  end

  defp not_schema(_schema, _value, _path, state), do: {[], state}

  defp conditional(%{"if" => condition} = schema, value, path, state) do
    {if_errors, if_evaluated, state} = eval(condition, value, path, state)
    branch = if if_errors == [], do: schema["then"], else: schema["else"]

    {errors, evaluated, state} =
      if branch == nil, do: {[], none(), state}, else: eval(branch, value, path, state)

    {errors, if(if_errors == [], do: merge(if_evaluated, evaluated), else: evaluated), state}
  end

  defp conditional(_schema, _value, _path, state), do: {[], none(), state}

  # ---- members

  defp members(schema, value, path, state) when is_map(value) do
    {e1, props1, state} = properties(schema, value, path, state)
    {e2, props2, state} = pattern_properties(schema, value, path, state)

    {e3, props3, state} =
      additional_properties(schema, value, path, MapSet.union(props1, props2), state)

    {e4, state} = property_names(schema, value, path, state)
    {e5, ev5, state} = dependent_schemas(schema, value, path, state)
    props = props1 |> MapSet.union(props2) |> MapSet.union(props3)
    {e1 ++ e2 ++ e3 ++ e4 ++ e5, merge(%{props: props, items: MapSet.new()}, ev5), state}
  end

  defp members(schema, value, path, state) when is_list(value),
    do: items(schema, value, path, state)

  defp members(_schema, _value, _path, state), do: {[], none(), state}

  defp properties(%{"properties" => props}, value, path, state) when is_map(props) do
    Enum.reduce(props, {[], MapSet.new(), state}, fn {name, sub}, {errors, seen, state} ->
      case Map.fetch(value, name) do
        {:ok, member} ->
          {e, _ev, state} = eval(sub, member, path ++ [name], state)
          {errors ++ e, MapSet.put(seen, name), state}

        :error ->
          {errors, seen, state}
      end
    end)
  end

  defp properties(_schema, _value, _path, state), do: {[], MapSet.new(), state}

  defp pattern_properties(%{"patternProperties" => patterns}, value, path, state)
       when is_map(patterns) do
    for {pattern, sub} <- patterns,
        {name, member} <- value,
        matches?(pattern, name),
        reduce: {[], MapSet.new(), state} do
      {errors, seen, state} ->
        {e, _ev, state} = eval(sub, member, path ++ [name], state)
        {errors ++ e, MapSet.put(seen, name), state}
    end
  end

  defp pattern_properties(_schema, _value, _path, state), do: {[], MapSet.new(), state}

  defp additional_properties(%{"additionalProperties" => sub}, value, path, matched, state) do
    extra = for {name, member} <- value, not MapSet.member?(matched, name), do: {name, member}
    members_against(sub, extra, path, state, "is not an accepted argument")
  end

  defp additional_properties(_schema, _value, _path, _matched, state),
    do: {[], MapSet.new(), state}

  # The members `sub` applies to: `false` refuses each by name, as the
  # argument checks always have.
  defp members_against(false, extra, path, state, message) do
    {Enum.map(extra, fn {name, _} -> error(path ++ [name], message) end), MapSet.new(), state}
  end

  defp members_against(sub, extra, path, state, _message) do
    Enum.reduce(extra, {[], MapSet.new(), state}, fn {name, member}, {errors, seen, state} ->
      {e, _ev, state} = eval(sub, member, path ++ [name], state)
      {errors ++ e, MapSet.put(seen, name), state}
    end)
  end

  defp property_names(%{"propertyNames" => sub}, value, path, state) do
    Enum.reduce(value, {[], state}, fn {name, _}, {errors, state} ->
      {e, _ev, state} = eval(sub, name, path ++ [name], state)

      case e do
        [] -> {errors, state}
        _ -> {errors ++ [error(path ++ [name], "is not an accepted property name")], state}
      end
    end)
  end

  defp property_names(_schema, _value, _path, state), do: {[], state}

  defp dependent_schemas(%{"dependentSchemas" => deps}, value, path, state) when is_map(deps) do
    for {name, sub} <- deps, Map.has_key?(value, name), reduce: {[], none(), state} do
      {errors, evaluated, state} ->
        {e, ev, state} = eval(sub, value, path, state)
        {errors ++ e, merge(evaluated, ev), state}
    end
  end

  defp dependent_schemas(_schema, _value, _path, state), do: {[], none(), state}

  defp items(schema, value, path, state) do
    indexed = Enum.with_index(value)
    prefix = if is_list(schema["prefixItems"]), do: schema["prefixItems"], else: []

    {e1, state} =
      prefix
      |> Enum.zip(indexed)
      |> Enum.reduce({[], state}, fn {sub, {item, i}}, {errors, state} ->
        {e, _ev, state} = eval(sub, item, path ++ [Integer.to_string(i)], state)
        {errors ++ e, state}
      end)

    evaluated_prefix = MapSet.new(0..(min(length(prefix), length(value)) - 1)//1)

    {e2, items_evaluated, state} =
      case Map.fetch(schema, "items") do
        {:ok, sub} ->
          rest = Enum.drop(indexed, length(prefix))
          {e, state} = each_item(sub, rest, path, state, "is not allowed")
          {e, :all, state}

        :error ->
          {[], evaluated_prefix, state}
      end

    {e3, contained, state} = contains(schema, indexed, path, state)

    {e1 ++ e2 ++ e3, %{props: MapSet.new(), items: merge_items(items_evaluated, contained)},
     state}
  end

  defp each_item(false, rest, path, state, message),
    do:
      {Enum.map(rest, fn {_item, i} -> error(path ++ [Integer.to_string(i)], message) end), state}

  defp each_item(sub, rest, path, state, _message) do
    Enum.reduce(rest, {[], state}, fn {item, i}, {errors, state} ->
      {e, _ev, state} = eval(sub, item, path ++ [Integer.to_string(i)], state)
      {errors ++ e, state}
    end)
  end

  defp contains(%{"contains" => sub} = schema, indexed, path, state) do
    {matching, state} =
      Enum.reduce(indexed, {[], state}, fn {item, i}, {matching, state} ->
        case eval(sub, item, path ++ [Integer.to_string(i)], state) do
          {[], _ev, state} -> {[i | matching], state}
          {_errors, _ev, state} -> {matching, state}
        end
      end)

    count = length(matching)
    min = if is_integer(schema["minContains"]), do: schema["minContains"], else: 1
    max = schema["maxContains"]

    errors =
      cond do
        count < min ->
          [
            error(
              path,
              "must contain at least #{min} matching item#{if min == 1, do: "", else: "s"}"
            )
          ]

        is_integer(max) and count > max ->
          [error(path, "must contain at most #{max} matching items")]

        true ->
          []
      end

    {errors, MapSet.new(matching), state}
  end

  defp contains(_schema, _indexed, _path, state), do: {[], MapSet.new(), state}

  defp unevaluated(schema, value, path, evaluated, state) when is_map(value) do
    case Map.fetch(schema, "unevaluatedProperties") do
      {:ok, sub} ->
        extra =
          for {name, member} <- value,
              not MapSet.member?(evaluated.props, name),
              do: {name, member}

        {errors, seen, state} =
          members_against(sub, extra, path, state, "is not an accepted argument")

        {errors, %{props: seen, items: MapSet.new()}, state}

      :error ->
        {[], none(), state}
    end
  end

  defp unevaluated(schema, value, path, evaluated, state) when is_list(value) do
    case Map.fetch(schema, "unevaluatedItems") do
      {:ok, sub} when evaluated.items != :all ->
        rest =
          for {item, i} <- Enum.with_index(value),
              not MapSet.member?(evaluated.items, i),
              do: {item, i}

        {errors, state} = each_item(sub, rest, path, state, "is not allowed")
        {errors, %{props: MapSet.new(), items: :all}, state}

      _ ->
        {[], none(), state}
    end
  end

  defp unevaluated(_schema, _value, _path, _evaluated, state), do: {[], none(), state}

  # ---- references

  # Every schema resource (the root, each `$id`) and `$anchor`, by its
  # absolute URI.
  defp index(schema) do
    Process.put(:sake_schema_nodes, 0)
    {:ok, index_node(schema, @base, %{@base => {schema, @base}})}
  rescue
    _ in [URI.Error, ArgumentError] -> {:error, "the schema has an invalid $id"}
  catch
    :sake_schema_too_large -> {:error, "the schema is too large to validate against"}
  after
    Process.delete(:sake_schema_nodes)
  end

  # Indexing visits every schema in the schema once: as many as it has,
  # up to the same bound as a validation's work.
  defp index_node(schema, base, acc) when is_map(schema) do
    nodes = Process.get(:sake_schema_nodes, 0) + 1
    if nodes > @max_steps, do: throw(:sake_schema_too_large)
    Process.put(:sake_schema_nodes, nodes)

    base = base(schema, base)
    acc = Map.put_new(acc, base, {schema, base})

    acc =
      case schema["$anchor"] do
        anchor when is_binary(anchor) -> Map.put(acc, base <> "#" <> anchor, {schema, base})
        _ -> acc
      end

    schema
    |> subschemas([])
    |> Enum.reduce(acc, fn {sub, _path}, acc -> index_node(sub, base, acc) end)
  end

  defp index_node(_schema, _base, acc), do: acc

  defp base(%{"$id" => id}, base) when is_binary(id) do
    base |> URI.merge(id) |> Map.put(:fragment, nil) |> URI.to_string()
  end

  defp base(_schema, base), do: base

  defp resolve(ref, index, base) do
    uri = URI.merge(base, ref)
    fragment = uri.fragment
    resource = uri |> Map.put(:fragment, nil) |> URI.to_string()

    case {Map.fetch(index, resource), fragment} do
      {{:ok, {schema, res_base}}, f} when f in [nil, ""] -> {:ok, schema, res_base}
      {{:ok, {schema, res_base}}, "/" <> pointer} -> follow(schema, pointer, res_base, index)
      {{:ok, _}, anchor} -> anchor(index, resource <> "#" <> anchor)
      {:error, _} -> :error
    end
  rescue
    _ in [URI.Error, ArgumentError] -> :error
  end

  defp anchor(index, key) do
    case Map.fetch(index, key) do
      {:ok, {schema, base}} -> {:ok, schema, base}
      :error -> :error
    end
  end

  # A JSON Pointer within a resource; an `$id` on the way changes the base.
  defp follow(schema, pointer, base, _index) do
    pointer
    |> String.split("/")
    |> Enum.map(&(&1 |> URI.decode() |> String.replace("~1", "/") |> String.replace("~0", "~")))
    |> Enum.reduce_while({:ok, schema, base}, fn token, {:ok, node, base} ->
      case step_into(node, token) do
        {:ok, next} -> {:cont, {:ok, next, base(next, base)}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp step_into(node, token) when is_map(node), do: Map.fetch(node, token)

  defp step_into(node, token) when is_list(node) do
    case Integer.parse(token) do
      {i, ""} when i >= 0 and i < length(node) -> {:ok, Enum.at(node, i)}
      _ -> :error
    end
  end

  defp step_into(_node, _token), do: :error

  # ---- helpers

  defp matches?(pattern, value) do
    case regex(pattern) do
      {:ok, regex} -> Regex.match?(regex, value)
      :error -> false
    end
  end

  defp regex(pattern) do
    case Regex.compile(pattern, "u") do
      {:ok, regex} -> {:ok, regex}
      {:error, _} -> :error
    end
  end

  defp error(path, message), do: %{path: path, message: message}

  defp pointer([]), do: "the schema"
  defp pointer(path), do: "#/" <> Enum.join(path, "/")
end
