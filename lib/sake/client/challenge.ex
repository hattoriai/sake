defmodule Sake.Client.Challenge do
  @moduledoc "A parsed `WWW-Authenticate` challenge."
  @type t :: %__MODULE__{}
  defstruct [:scheme, :resource_metadata, :error, :error_description, :realm, scope: []]

  @spec parse(String.t()) :: t()
  def parse(header) do
    {scheme, rest} =
      case String.split(String.trim(header), " ", parts: 2) do
        [scheme] -> {scheme, ""}
        [scheme, rest] -> {scheme, rest}
      end

    params =
      ~r/(\w+)="([^"]*)"|(\w+)=([^,\s]+)/
      |> Regex.scan(rest)
      |> Map.new(fn
        [_, k, v] -> {k, v}
        [_, "", "", k, v] -> {k, v}
      end)

    %__MODULE__{
      scheme: scheme,
      resource_metadata: params["resource_metadata"],
      error: params["error"],
      error_description: params["error_description"],
      realm: params["realm"],
      scope: params |> Map.get("scope", "") |> String.split(" ", trim: true)
    }
  end
end
