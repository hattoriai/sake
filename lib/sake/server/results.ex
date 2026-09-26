defmodule Sake.Server.Results do
  @moduledoc false
  # Turns what a component returns into the wire result.

  alias Sake.Content

  @spec tool(term(), Sake.Tool.Spec.t(), Sake.Context.t()) :: map()
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
          json = JSON.encode!(structured)

          %{
            "content" => [Content.to_wire(Content.text(json))],
            "structuredContent" => JSON.decode!(json)
          }

        other ->
          %{"content" => [Content.to_wire(Content.text(to_string(other)))]}
      end

    base = Map.put(base, "isError", false)
    if meta = opts[:meta], do: Map.put(base, "_meta", meta), else: base
  end

  def tool({:error, text}, _spec, _ctx) when is_binary(text) do
    %{"content" => [Content.to_wire(Content.text(text))], "isError" => true}
  end

  @spec resource(term(), Sake.Resource.Spec.t(), String.t(), Sake.Context.t()) ::
          {:ok, map()} | {:error, :not_found | String.t()}
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
            Content.resource(uri, JSON.encode!(data),
              mime_type: spec.mime_type || "application/json"
            )
          ]
      end

    {:ok,
     %{"contents" => Enum.map(contents, &(&1 |> Content.to_wire() |> Map.fetch!("resource")))}}
  end

  def resource({:error, reason}, _spec, _uri, _ctx), do: {:error, reason}

  @spec prompt(term(), Sake.Prompt.Spec.t(), Sake.Context.t()) ::
          {:ok, map()} | {:error, String.t()}
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
