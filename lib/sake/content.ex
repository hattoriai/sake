defmodule Sake.Content do
  @moduledoc """
  A content block of a tool result, a resource read, or a prompt message.
  """

  @type t :: %__MODULE__{
          type: :text | :image | :audio | :resource_link | :resource,
          text: String.t() | nil,
          data: binary() | nil,
          mime_type: String.t() | nil,
          uri: String.t() | nil,
          name: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          blob: boolean(),
          annotations: map() | nil,
          meta: map() | nil
        }

  defstruct [
    :type,
    :text,
    :data,
    :mime_type,
    :uri,
    :name,
    :title,
    :description,
    :annotations,
    :meta,
    blob: false
  ]

  @spec text(String.t(), keyword()) :: t()
  def text(text, opts \\ []), do: struct!(__MODULE__, [type: :text, text: text] ++ common(opts))

  @spec image(binary(), String.t(), keyword()) :: t()
  def image(data, mime, opts \\ []),
    do: struct!(__MODULE__, [type: :image, data: data, mime_type: mime] ++ common(opts))

  @spec audio(binary(), String.t(), keyword()) :: t()
  def audio(data, mime, opts \\ []),
    do: struct!(__MODULE__, [type: :audio, data: data, mime_type: mime] ++ common(opts))

  @spec resource_link(String.t(), keyword()) :: t()
  def resource_link(uri, opts \\ []) do
    struct!(
      __MODULE__,
      [type: :resource_link, uri: uri] ++
        Keyword.take(opts, [:name, :title, :description, :mime_type]) ++ common(opts)
    )
  end

  @doc "An embedded resource: `content` is text, or `{:blob, binary}`."
  @spec resource(String.t(), String.t() | {:blob, binary()}, keyword()) :: t()
  def resource(uri, content, opts \\ []) do
    base = [type: :resource, uri: uri, mime_type: opts[:mime_type]] ++ common(opts)

    case content do
      {:blob, bin} -> struct!(__MODULE__, base ++ [data: bin, blob: true])
      text when is_binary(text) -> struct!(__MODULE__, base ++ [text: text])
    end
  end

  defp common(opts), do: Keyword.take(opts, [:annotations, :meta])

  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{type: :text} = c),
    do: %{"type" => "text", "text" => c.text} |> extras(c)

  def to_wire(%__MODULE__{type: :image} = c),
    do:
      %{"type" => "image", "data" => Base.encode64(c.data), "mimeType" => c.mime_type}
      |> extras(c)

  def to_wire(%__MODULE__{type: :audio} = c),
    do:
      %{"type" => "audio", "data" => Base.encode64(c.data), "mimeType" => c.mime_type}
      |> extras(c)

  def to_wire(%__MODULE__{type: :resource_link} = c) do
    %{"type" => "resource_link", "uri" => c.uri}
    |> put_some("name", c.name)
    |> put_some("title", c.title)
    |> put_some("description", c.description)
    |> put_some("mimeType", c.mime_type)
    |> extras(c)
  end

  def to_wire(%__MODULE__{type: :resource, blob: true} = c) do
    %{
      "type" => "resource",
      "resource" =>
        %{"uri" => c.uri, "blob" => Base.encode64(c.data)} |> put_some("mimeType", c.mime_type)
    }
    |> extras(c)
  end

  def to_wire(%__MODULE__{type: :resource} = c) do
    %{
      "type" => "resource",
      "resource" => %{"uri" => c.uri, "text" => c.text} |> put_some("mimeType", c.mime_type)
    }
    |> extras(c)
  end

  @spec from_wire(map()) :: t() | {:error, :unknown_content}
  def from_wire(%{"type" => "text", "text" => t} = w),
    do: %__MODULE__{type: :text, text: t} |> take_extras(w)

  def from_wire(%{"type" => "image", "data" => d, "mimeType" => m} = w) do
    case Base.decode64(d) do
      {:ok, data} -> %__MODULE__{type: :image, data: data, mime_type: m} |> take_extras(w)
      :error -> {:error, :unknown_content}
    end
  end

  def from_wire(%{"type" => "audio", "data" => d, "mimeType" => m} = w) do
    case Base.decode64(d) do
      {:ok, data} -> %__MODULE__{type: :audio, data: data, mime_type: m} |> take_extras(w)
      :error -> {:error, :unknown_content}
    end
  end

  def from_wire(%{"type" => "resource_link", "uri" => u} = w) do
    %__MODULE__{
      type: :resource_link,
      uri: u,
      name: w["name"],
      title: w["title"],
      description: w["description"],
      mime_type: w["mimeType"]
    }
    |> take_extras(w)
  end

  def from_wire(%{"type" => "resource", "resource" => %{"uri" => u, "blob" => b} = r} = w) do
    case Base.decode64(b) do
      {:ok, data} ->
        %__MODULE__{
          type: :resource,
          uri: u,
          data: data,
          blob: true,
          mime_type: r["mimeType"]
        }
        |> take_extras(w)

      :error ->
        {:error, :unknown_content}
    end
  end

  def from_wire(%{"type" => "resource", "resource" => %{"uri" => u, "text" => t} = r} = w) do
    %__MODULE__{type: :resource, uri: u, text: t, mime_type: r["mimeType"]} |> take_extras(w)
  end

  def from_wire(_), do: {:error, :unknown_content}

  defp extras(map, c) do
    map |> put_some("annotations", annotations(c.annotations)) |> put_some("_meta", c.meta)
  end

  defp take_extras(c, w),
    do: %{c | annotations: annotations_in(w["annotations"]), meta: w["_meta"]}

  defp annotations(nil), do: nil
  defp annotations(a) when a == %{}, do: nil

  defp annotations(a) do
    a
    |> Enum.map(fn
      {:audience, list} -> {"audience", Enum.map(list, &to_string/1)}
      {:priority, p} -> {"priority", p}
      {:last_modified, t} -> {"lastModified", t}
      {k, v} -> {to_string(k), v}
    end)
    |> Map.new()
  end

  defp annotations_in(nil), do: nil

  defp annotations_in(a) do
    a
    |> Enum.map(fn
      {"audience", list} -> {:audience, Enum.map(list, &safe_audience_atom/1)}
      {"priority", p} -> {:priority, p}
      {"lastModified", t} -> {:last_modified, t}
      {k, v} -> {k, v}
    end)
    |> Map.new()
  end

  defp safe_audience_atom("user"), do: :user
  defp safe_audience_atom("assistant"), do: :assistant
  defp safe_audience_atom(s), do: s

  defp put_some(map, _key, nil), do: map
  defp put_some(map, key, value), do: Map.put(map, key, value)
end
