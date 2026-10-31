defmodule Sake.Server.Results do
  @moduledoc false
  # Turns what a component returns into the wire result.

  require Logger

  alias Sake.Content
  alias Sake.Tool.Result

  # `structuredContent` may be any JSON value from this revision on;
  # before it, only an object.
  @any_structured "2026-07-28"

  @spec tool(term(), Sake.Tool.Spec.t() | nil, Sake.Context.t()) :: map()
  def tool({:ok, value}, spec, ctx), do: tool({:ok, value, []}, spec, ctx)

  def tool({:ok, %Result{} = result, opts}, spec, ctx) do
    content =
      cond do
        result.content -> Enum.map(result.content, &Content.to_wire/1)
        result.text -> [text_block(result.text)]
        result.structured? -> [text_block(Sake.JSON.encode!(result.structured))]
        true -> []
      end

    %{"content" => content, "isError" => result.error}
    |> put_structured(result, ctx)
    |> put_meta(merge_meta(result.meta, opts[:meta]))
    |> check_output(spec)
  end

  def tool({:ok, value, opts}, spec, ctx) do
    value
    |> tool_content(opts[:text])
    |> Map.put("isError", false)
    |> compatible(ctx)
    |> put_meta(opts[:meta])
    |> check_output(spec)
  end

  def tool({:error, text}, _spec, _ctx) when is_binary(text) do
    %{"content" => [Content.to_wire(Content.text(text))], "isError" => true}
  end

  defp tool_content(text, nil) when is_binary(text), do: %{"content" => [text_block(text)]}

  defp tool_content([%Content{} | _] = list, nil),
    do: %{"content" => Enum.map(list, &Content.to_wire/1)}

  defp tool_content([], nil), do: %{"content" => []}
  defp tool_content([%Content{} | _] = value, _text), do: text_needs_data!(value)

  defp tool_content(structured, text) when is_map(structured) or is_list(structured) do
    json = Sake.JSON.encode!(structured)
    %{"content" => model_content(text, json), "structuredContent" => JSON.decode!(json)}
  end

  defp tool_content(other, nil), do: %{"content" => [text_block(to_string(other))]}
  defp tool_content(value, _text), do: text_needs_data!(value)

  defp put_structured(wire, %Result{structured?: false}, _ctx), do: wire

  defp put_structured(wire, %Result{structured: value}, ctx) do
    value = value |> Sake.JSON.encode!() |> JSON.decode!()

    if is_map(value) or any_structured?(ctx),
      do: Map.put(wire, "structuredContent", value),
      else: wire
  end

  @doc false
  # A result whose structuredContent is not an object (a list result's,
  # say), which a revision before 2026-07-28 does not allow: there, the
  # model's text carries it alone.
  def compatible(%{"structuredContent" => value} = wire, ctx) when not is_map(value) do
    if any_structured?(ctx), do: wire, else: Map.delete(wire, "structuredContent")
  end

  def compatible(wire, _ctx), do: wire

  defp any_structured?(%{protocol_version: revision}) when is_binary(revision),
    do: revision >= @any_structured

  defp any_structured?(_ctx), do: true

  defp put_meta(wire, nil), do: wire
  defp put_meta(wire, meta), do: Map.put(wire, "_meta", meta)

  defp merge_meta(nil, meta), do: meta
  defp merge_meta(meta, nil), do: meta
  defp merge_meta(a, b), do: Map.merge(a, b)

  # A local tool's structured result is checked against its output
  # schema: a mismatch is logged, or, with `validate_output: :error`, the
  # client gets a tool error instead of the result. A proxied tool's is
  # its upstream's to check.
  defp check_output(
         %{"structuredContent" => value} = wire,
         %Sake.Tool.Spec{module: module} = spec
       )
       when module != nil and is_map(spec.output_schema) do
    case Sake.Schema.Validator.validate(spec.output_schema, value) do
      :ok ->
        wire

      {:error, errors} ->
        detail = Enum.map_join(errors, "; ", &"#{path(&1.path)}: #{&1.message}")

        if spec.validate_output == :error do
          %{
            "content" => [
              text_block("The tool's result does not match its output schema: " <> detail)
            ],
            "isError" => true
          }
        else
          Logger.warning(
            "tool #{spec.name}: the result does not match its output schema: #{detail}"
          )

          wire
        end
    end
  end

  defp check_output(wire, _spec), do: wire

  defp path([]), do: "(the result)"
  defp path(path), do: Enum.join(path, ".")

  defp text_needs_data!(value) do
    raise ArgumentError, "a tool's `text:` needs a map or a list result, got: #{inspect(value)}"
  end

  defp text_block(text), do: Content.to_wire(Content.text(text))

  # What the model reads next to `structuredContent`: the data's JSON by
  # default, or the tool's own `text:` (a string or a content list).
  defp model_content(nil, json), do: [text_block(json)]
  defp model_content(text, _json) when is_binary(text), do: [text_block(text)]
  defp model_content(list, _json) when is_list(list), do: Enum.map(list, &Content.to_wire/1)

  @spec resource(term(), Sake.Resource.Spec.t(), String.t(), Sake.Context.t()) ::
          {:ok, map()} | {:error, :not_found | String.t() | {:missing_capability, map()}}
  def resource({:ok, value}, spec, uri, _ctx) do
    contents =
      case value do
        text when is_binary(text) ->
          [Content.resource(uri, text, mime_type: spec.mime_type)]

        {:blob, bin, mime} ->
          [Content.resource(uri, {:blob, bin}, mime_type: mime)]

        [%Content{} | _] = list ->
          list

        data when is_map(data) or is_list(data) ->
          [
            Content.resource(uri, Sake.JSON.encode!(data),
              mime_type: spec.mime_type || "application/json"
            )
          ]
      end

    {:ok,
     %{
       "contents" =>
         Enum.map(contents, &(&1 |> Content.to_wire() |> Map.fetch!("resource") |> ui_meta(spec)))
     }}
  end

  def resource({:error, reason}, _spec, _uri, _ctx), do: {:error, reason}

  # An MCP App's contents carry the resource's `_meta` (its `_meta.ui`,
  # with the CSP the host enforces), as its `resources/list` entry does.
  defp ui_meta(content, %{ui: true, meta: meta}) when is_map(meta),
    do: Map.put_new(content, "_meta", meta)

  defp ui_meta(content, _spec), do: content

  @spec prompt(term(), Sake.Prompt.Spec.t(), Sake.Context.t()) ::
          {:ok, map()} | {:error, String.t() | {:missing_capability, map()}}
  def prompt({:ok, messages}, spec, ctx), do: prompt({:ok, messages, []}, spec, ctx)

  def prompt({:ok, messages, opts}, spec, _ctx) do
    wire =
      Enum.map(messages, fn {role, content} ->
        content = if is_binary(content), do: Content.text(content), else: content
        %{"role" => to_string(role), "content" => Content.to_wire(content)}
      end)

    result = %{"messages" => wire}
    description = opts[:description] || spec.description
    {:ok, if(description, do: Map.put(result, "description", description), else: result)}
  end

  def prompt({:error, text}, _spec, _ctx), do: {:error, text}
end
