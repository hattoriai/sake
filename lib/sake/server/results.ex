defmodule Sake.Server.Results do
  @moduledoc false
  # Turns what a component returns into the wire result.

  alias Sake.Content

  @spec tool(term(), Sake.Tool.Spec.t() | nil, Sake.Context.t()) :: map()
  def tool({:ok, value}, spec, ctx), do: tool({:ok, value, []}, spec, ctx)

  def tool({:ok, value, opts}, _spec, _ctx) do
    base =
      case value do
        text when is_binary(text) ->
          %{"content" => [Content.to_wire(Content.text(text))]}

        [%Content{} | _] = list ->
          %{"content" => Enum.map(list, &Content.to_wire/1)}

        [] ->
          %{"content" => []}

        structured when is_map(structured) or is_list(structured) ->
          json = Sake.JSON.encode!(structured)

          %{
            "content" => model_content(opts[:text], json),
            "structuredContent" => JSON.decode!(json)
          }

        other ->
          %{"content" => [Content.to_wire(Content.text(to_string(other)))]}
      end

    if opts[:text] && not Map.has_key?(base, "structuredContent") do
      raise ArgumentError,
            "a tool's `text:` needs a map or a list result, got: #{inspect(value)}"
    end

    base = Map.put(base, "isError", false)
    if meta = opts[:meta], do: Map.put(base, "_meta", meta), else: base
  end

  def tool({:error, text}, _spec, _ctx) when is_binary(text) do
    %{"content" => [Content.to_wire(Content.text(text))], "isError" => true}
  end

  # What the model reads next to `structuredContent`: the data's JSON by
  # default, or the tool's own `text:` (a string or a content list).
  defp model_content(nil, json), do: [Content.to_wire(Content.text(json))]
  defp model_content(text, _json) when is_binary(text), do: [Content.to_wire(Content.text(text))]
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
