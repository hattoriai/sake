defmodule Sake.Skill.Frontmatter do
  @moduledoc """
  The YAML frontmatter of a `SKILL.md`: the block between the leading
  `---` lines.

  Sake has no YAML dependency, so this reads the subset of YAML that skill
  frontmatter is written in, and refuses the rest with an error that says
  which line, instead of guessing: a client parses the same text with a
  full YAML parser and compares the result, field by field, with the
  `frontmatter` of the skill's entry, so a value read differently here
  would make it refuse the skill.

  What it reads: `key: value` mappings, nested by indentation; block
  sequences (`- item`); plain scalars, which may run over several lines;
  single- and double-quoted scalars; literal (`|`) and folded (`>`) block
  scalars with their chomping indicators (`-`, `+`); comments. Plain
  scalars resolve as the YAML 1.2 core schema does: `null`, `~` or
  nothing is `nil`, `true` and `false` (in any of their three casings)
  are booleans, and decimal, octal (`0o`), hexadecimal (`0x`) and
  floating-point numbers are numbers. Flow collections (`{}` and `[]`),
  anchors, aliases, tags, complex keys and multiple documents are refused.
  """

  @typedoc "A parsed value."
  @type value :: String.t() | number() | boolean() | nil | [value()] | %{String.t() => value()}

  @doc """
  Splits `text` into its frontmatter, parsed, and the body after it.
  A leading byte-order mark is skipped.
  """
  @spec split(String.t()) :: {:ok, map(), String.t()} | {:error, String.t()}
  def split(text) when is_binary(text) do
    text = String.replace_prefix(text, "﻿", "")

    case Regex.run(~r/\A---[ \t]*\r?\n(.*?)(?:\r?\n|\A)---[ \t]*(?:\r?\n|\z)/s, text,
           return: :index
         ) do
      [{0, len}, {start, block_len}] ->
        block = binary_part(text, start, block_len)
        body = binary_part(text, len, byte_size(text) - len)

        with {:ok, map} <- parse(block), do: {:ok, map, body}

      nil ->
        {:error,
         "SKILL.md has no frontmatter: it must start with a --- line, and a --- line must end it"}
    end
  end

  @doc "Parses a frontmatter block (the text between the `---` lines) into a map."
  @spec parse(String.t()) :: {:ok, map()} | {:error, String.t()}
  def parse(block) do
    lines =
      block
      |> String.split(~r/\r?\n/)
      |> Enum.with_index(2)
      |> Enum.map(fn {text, n} -> {n, text} end)

    case parse_node(lines, 0) do
      {:ok, %{} = map, []} ->
        {:ok, map}

      {:ok, nil, []} ->
        {:ok, %{}}

      {:ok, _other, []} ->
        {:error, "the frontmatter must be a mapping of keys to values"}

      {:ok, _value, [{n, _} | _]} ->
        {:error, "line #{n} of SKILL.md: unexpected indentation"}
    end
  catch
    {:frontmatter, n, message} -> {:error, "line #{n} of SKILL.md: #{message}"}
    {:frontmatter_value, message} -> {:error, "the frontmatter of SKILL.md: #{message}"}
  end

  # ---- structure

  defp blank_or_comment?(text), do: Regex.match?(~r/\A\s*(#.*)?\z/, text)

  defp indent(text), do: byte_size(text) - byte_size(String.trim_leading(text, " "))

  defp skip_blank(lines), do: Enum.drop_while(lines, fn {_n, t} -> blank_or_comment?(t) end)

  # The node at `min` indentation or deeper: a mapping, a sequence, or
  # nothing (an empty value).
  defp parse_node(lines, min) do
    case skip_blank(lines) do
      [] ->
        {:ok, nil, []}

      [{n, text} | _] = rest ->
        check_tabs!(n, text)
        ind = indent(text)

        cond do
          ind < min -> {:ok, nil, rest}
          sequence_item?(text) -> parse_sequence(rest, ind, [])
          true -> parse_mapping(rest, ind, %{})
        end
    end
  end

  defp check_tabs!(n, text) do
    if Regex.match?(~r/\A {0,}\t/, text),
      do: throw({:frontmatter, n, "indentation must be spaces, not tabs"})
  end

  defp sequence_item?(text), do: Regex.match?(~r/\A\s*-(\s|\z)/, text)

  defp parse_mapping(lines, ind, acc) do
    case skip_blank(lines) do
      [{n, text} | rest] = all ->
        check_tabs!(n, text)

        cond do
          indent(text) < ind ->
            {:ok, acc, all}

          indent(text) > ind ->
            throw({:frontmatter, n, "unexpected indentation"})

          sequence_item?(text) ->
            throw({:frontmatter, n, "a sequence item where a key was expected"})

          true ->
            {key, value, rest} = mapping_entry(n, text, rest, ind, acc)
            parse_mapping(rest, ind, Map.put(acc, key, value))
        end

      [] ->
        {:ok, acc, []}
    end
  end

  defp parse_sequence(lines, ind, acc) do
    case skip_blank(lines) do
      [{n, text} | rest] = all ->
        check_tabs!(n, text)

        cond do
          indent(text) < ind ->
            {:ok, Enum.reverse(acc), all}

          indent(text) > ind ->
            throw({:frontmatter, n, "unexpected indentation"})

          not sequence_item?(text) ->
            {:ok, Enum.reverse(acc), all}

          true ->
            {value, rest} = sequence_item(n, text, rest, ind)
            parse_sequence(rest, ind, [value | acc])
        end

      [] ->
        {:ok, Enum.reverse(acc), []}
    end
  end

  defp mapping_entry(n, text, rest, ind, acc) do
    {key, value_text} = split_key!(n, String.trim_leading(text, " "))

    if Map.has_key?(acc, key),
      do: throw({:frontmatter, n, "the key #{inspect(key)} appears twice"})

    {value, rest} = parse_value(n, value_text, rest, ind, :mapping)
    {key, value, rest}
  end

  # An item's value: on its own line, or nested below it.
  defp sequence_item(n, text, rest, ind) do
    item =
      text |> String.trim_leading(" ") |> String.replace_prefix("-", "") |> String.trim_leading()

    cond do
      item == "" ->
        nested(rest, ind + 1)

      key_line?(item) ->
        throw({:frontmatter, n, "a mapping inside a sequence item is not supported"})

      true ->
        parse_value(n, item, rest, ind, :sequence)
    end
  end

  defp nested(lines, min) do
    {:ok, value, rest} = parse_node(lines, min)
    {value, rest}
  end

  defp key_line?(text), do: Regex.match?(~r/\A[^"'#\s][^:#]*:(\s|\z)/, text)

  defp split_key!(n, text) do
    reject_unsupported!(n, text)

    case Regex.run(
           ~r/\A([^"'#\s][^:]*?|"(?:[^"\\]|\\.)*"|'(?:[^']|'')*')\s*:(?:\s+(.*)|\z)/,
           text,
           capture: :all_but_first
         ) do
      [key] -> {key_text(n, key), ""}
      [key, value] -> {key_text(n, key), value}
      nil -> throw({:frontmatter, n, "expected `key: value`"})
    end
  end

  defp key_text(n, key) do
    case scalar(n, key) do
      value when is_binary(value) -> value
      _ -> key
    end
  end

  defp reject_unsupported!(n, text) do
    cond do
      String.starts_with?(text, "? ") ->
        throw({:frontmatter, n, "complex keys are not supported"})

      String.starts_with?(text, "---") or String.starts_with?(text, "...") ->
        throw({:frontmatter, n, "multiple documents are not supported"})

      true ->
        :ok
    end
  end

  # The value after `key:` or `- `: inline, a block scalar, or a nested
  # node on the lines below.
  # A quoted value reads its own trailing comment: a `#` inside the quotes
  # is part of the value.
  defp parse_value(n, "\"" <> _ = text, rest, _ind, _context),
    do: quoted(n, String.trim_trailing(text), rest, ?")

  defp parse_value(n, "'" <> _ = text, rest, _ind, _context),
    do: quoted(n, String.trim_trailing(text), rest, ?')

  defp parse_value(n, text, rest, ind, context) do
    text = strip_comment(text)

    cond do
      text == "" ->
        nested_value(rest, ind, context)

      String.starts_with?(text, "|") or String.starts_with?(text, ">") ->
        block_scalar(n, text, rest, ind)

      true ->
        reject_inline!(n, text)
        {more, rest} = continuation(rest, ind)
        {resolve(Enum.join([text | more], " ")), rest}
    end
  end

  # A key with nothing after it holds what is indented below it: for a
  # mapping's key, a sequence may also sit at the key's own indentation.
  defp nested_value(rest, ind, :mapping) do
    case skip_blank(rest) do
      [{_n, text} | _] = lines ->
        cond do
          indent(text) > ind -> nested(lines, ind + 1)
          indent(text) == ind and sequence_item?(text) -> nested(lines, ind)
          true -> {nil, lines}
        end

      [] ->
        {nil, []}
    end
  end

  defp nested_value(rest, ind, :sequence), do: nested(rest, ind + 1)

  defp reject_inline!(n, text) do
    cond do
      String.starts_with?(text, ["{", "["]) ->
        throw({:frontmatter, n, "flow collections ({...} and [...]) are not supported"})

      String.starts_with?(text, ["&", "*"]) ->
        throw({:frontmatter, n, "anchors and aliases are not supported"})

      String.starts_with?(text, "!") ->
        throw({:frontmatter, n, "tags are not supported"})

      String.starts_with?(text, ["@", "`"]) ->
        throw({:frontmatter, n, "a plain value cannot start with #{String.first(text)}"})

      String.starts_with?(text, ["%"]) ->
        throw({:frontmatter, n, "directives are not supported"})

      Regex.match?(~r/:(\s|\z)/, text) ->
        throw({:frontmatter, n, "a value that contains `: ` must be quoted"})

      true ->
        :ok
    end
  end

  # The lines that continue a plain scalar: more indented than its key,
  # and not themselves a key or a sequence item.
  defp continuation(lines, ind), do: continuation(lines, ind, [])

  defp continuation([{n, text} | rest] = lines, ind, acc) do
    cond do
      blank_or_comment?(text) and String.trim(text) == "" ->
        throw_if_continued(rest, ind, n, acc, lines)

      blank_or_comment?(text) ->
        {Enum.reverse(acc), lines}

      indent(text) > ind ->
        check_tabs!(n, text)
        line = text |> String.trim() |> strip_comment()

        if key_line?(line) or sequence_item?(text),
          do: throw({:frontmatter, n, "unexpected indentation"})

        reject_inline!(n, line)
        continuation(rest, ind, [line | acc])

      true ->
        {Enum.reverse(acc), lines}
    end
  end

  defp continuation([], _ind, acc), do: {Enum.reverse(acc), []}

  # A blank line inside a multi-line plain scalar would be a line break
  # in its value: refused rather than read one way or the other.
  defp throw_if_continued(rest, ind, n, acc, lines) do
    case skip_blank(rest) do
      [{_m, text} | _] when acc != [] ->
        if indent(text) > ind and not key_line?(String.trim(text)),
          do: throw({:frontmatter, n, "a blank line inside a plain value is not supported"}),
          else: {Enum.reverse(acc), lines}

      _ ->
        {Enum.reverse(acc), lines}
    end
  end

  defp strip_comment(text) do
    text
    |> then(&Regex.replace(~r/\s+#.*\z/, &1, ""))
    |> then(&if(String.starts_with?(&1, "#"), do: "", else: &1))
    |> String.trim_trailing()
  end

  # ---- scalars

  defp scalar(n, text) do
    cond do
      String.starts_with?(text, "\"") -> double(n, String.slice(text, 1..-2//1))
      String.starts_with?(text, "'") -> single(String.slice(text, 1..-2//1))
      true -> resolve(text)
    end
  end

  # A quoted scalar on one line, with nothing but a comment after it.
  defp quoted(n, text, rest, quote) do
    pattern =
      if quote == ?",
        do: ~r/\A"((?:[^"\\]|\\.)*)"\s*(#.*)?\z/,
        else: ~r/\A'((?:[^']|'')*)'\s*(#.*)?\z/

    case Regex.run(pattern, text, capture: :all_but_first) do
      [inner | _] when quote == ?" -> {double(n, inner), rest}
      [inner | _] -> {single(inner), rest}
      nil -> throw({:frontmatter, n, "a quoted value must open and close on the same line"})
    end
  end

  defp single(inner), do: String.replace(inner, "''", "'")

  @escapes %{
    "0" => <<0>>,
    "a" => <<7>>,
    "b" => <<8>>,
    "t" => "\t",
    "\t" => "\t",
    "n" => "\n",
    "v" => <<11>>,
    "f" => <<12>>,
    "r" => "\r",
    "e" => <<27>>,
    " " => " ",
    "\"" => "\"",
    "/" => "/",
    "\\" => "\\",
    "N" => <<0x85::utf8>>,
    "_" => <<0xA0::utf8>>,
    "L" => <<0x2028::utf8>>,
    "P" => <<0x2029::utf8>>
  }

  defp double(n, inner), do: double(n, inner, [])

  defp double(_n, "", acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp double(n, "\\" <> rest, acc) do
    case rest do
      "x" <> <<hex::binary-size(2), rest::binary>> -> double(n, rest, [codepoint(n, hex) | acc])
      "u" <> <<hex::binary-size(4), rest::binary>> -> double(n, rest, [codepoint(n, hex) | acc])
      "U" <> <<hex::binary-size(8), rest::binary>> -> double(n, rest, [codepoint(n, hex) | acc])
      <<c::utf8, rest::binary>> -> double(n, rest, [escape(n, <<c::utf8>>) | acc])
    end
  end

  defp double(n, <<c::utf8, rest::binary>>, acc), do: double(n, rest, [<<c::utf8>> | acc])

  defp escape(n, c) do
    case Map.fetch(@escapes, c) do
      {:ok, value} -> value
      :error -> throw({:frontmatter, n, "unknown escape \\#{c} in a double-quoted value"})
    end
  end

  defp codepoint(n, hex) do
    case Integer.parse(hex, 16) do
      {cp, ""} -> <<cp::utf8>>
      _ -> throw({:frontmatter, n, "invalid escape \\x, \\u or \\U in a double-quoted value"})
    end
  end

  # A literal or folded block scalar: the lines more indented than its
  # key, with the indentation of the first of them removed.
  defp block_scalar(n, header, rest, ind) do
    {style, chomp, explicit} = block_header!(n, header)

    {lines, rest} =
      Enum.split_while(rest, fn {_m, t} -> String.trim(t) == "" or indent(t) > ind end)

    # Trailing blank lines belong to the block only for its chomping.
    content_ind =
      (explicit && ind + explicit) ||
        Enum.find_value(lines, ind + 1, fn {_m, t} -> String.trim(t) != "" && indent(t) end)

    {content, trailing} = lines |> Enum.map(&dedent(&1, content_ind)) |> split_trailing()
    body = if style == :literal, do: Enum.join(content, "\n"), else: fold(content)
    {chomp(body, content, trailing, chomp), rest}
  end

  defp dedent({m, t}, content_ind) do
    cond do
      String.trim(t) == "" ->
        ""

      indent(t) < content_ind ->
        throw({:frontmatter, m, "a block scalar line is less indented than its first line"})

      true ->
        binary_part(t, content_ind, byte_size(t) - content_ind)
    end
  end

  defp chomp(_body, [], trailing, :keep), do: String.duplicate("\n", length(trailing))
  defp chomp(_body, [], _trailing, _chomp), do: ""
  defp chomp(body, _content, _trailing, :strip), do: body
  defp chomp(body, _content, _trailing, :clip), do: body <> "\n"

  defp chomp(body, _content, trailing, :keep),
    do: body <> "\n" <> String.duplicate("\n", length(trailing))

  defp block_header!(n, header) do
    case Regex.run(~r/\A([|>])([-+]?)([1-9]?)([-+]?)\s*(#.*)?\z/, header, capture: :all_but_first) do
      [style, c1, digit, c2 | _] when c1 == "" or c2 == "" ->
        {if(style == "|", do: :literal, else: :folded),
         case c1 <> c2 do
           "-" -> :strip
           "+" -> :keep
           "" -> :clip
         end, if(digit == "", do: nil, else: String.to_integer(digit))}

      _ ->
        throw({:frontmatter, n, "invalid block scalar header #{inspect(header)}"})
    end
  end

  defp split_trailing(texts) do
    {trailing, content} = texts |> Enum.reverse() |> Enum.split_while(&(&1 == ""))
    {Enum.reverse(content), trailing}
  end

  # Folding: a line break between two non-empty lines that are not more
  # indented becomes a space; each empty line between them stays a line
  # break; more-indented lines keep their breaks.
  defp fold(lines) do
    lines
    |> Enum.reduce({[], nil}, fn line, {acc, prev} ->
      sep =
        cond do
          prev == nil -> ""
          line == "" -> "\n"
          prev == "" -> ""
          more_indented?(line) or more_indented?(prev) -> "\n"
          true -> " "
        end

      {[line, sep | acc], line}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp more_indented?(line), do: String.starts_with?(line, [" ", "\t"])

  # ---- the core schema

  defp resolve(text) when text in ["", "~", "null", "Null", "NULL"], do: nil
  defp resolve(text) when text in ["true", "True", "TRUE"], do: true
  defp resolve(text) when text in ["false", "False", "FALSE"], do: false

  defp resolve(text) do
    cond do
      Regex.match?(~r/\A[-+]?[0-9]+\z/, text) ->
        String.to_integer(String.replace_prefix(text, "+", ""))

      Regex.match?(~r/\A0o[0-7]+\z/, text) ->
        String.to_integer(String.slice(text, 2..-1//1), 8)

      Regex.match?(~r/\A0x[0-9a-fA-F]+\z/, text) ->
        String.to_integer(String.slice(text, 2..-1//1), 16)

      Regex.match?(~r/\A[-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?\z/, text) ->
        float(text)

      Regex.match?(~r/\A([-+]?\.(inf|Inf|INF)|\.(nan|NaN|NAN))\z/, text) ->
        throw({:frontmatter_value, "#{text} has no JSON value"})

      true ->
        text
    end
  end

  defp float(text) do
    normalized =
      text
      |> String.replace_prefix("+", "")
      |> then(&if(String.starts_with?(&1, "."), do: "0" <> &1, else: &1))
      |> then(
        &if(String.starts_with?(&1, "-."), do: "-0" <> String.slice(&1, 1..-1//1), else: &1)
      )
      |> String.replace(~r/\.([eE]|\z)/, ".0\\1")
      |> then(
        &if(String.contains?(&1, "."), do: &1, else: String.replace(&1, ~r/([eE])/, ".0\\1"))
      )

    {value, ""} = Float.parse(normalized)
    value
  end
end
