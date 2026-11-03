defmodule Sake.Actors.ActAs do
  @moduledoc false
  # `act_as`, on a server with `actors` (`Sake.Actors`).

  use Sake.Tool,
    name: "act_as",
    title: "Act as",
    description:
      "Takes on an identity from list_actors: returns its name and instructions. " <>
        "Follow them, and pass its id as `as` to every tool while you act as it.",
    annotations: [read_only: true, idempotent: true]

  arg :id, :string, required: true, description: "The id of an identity, from list_actors"

  alias Sake.Actors
  alias Sake.Actors.Actor

  @impl true
  def execute(%{id: id}, ctx) do
    case Actors.fetch(Actors.module(ctx), ctx, id) do
      {:ok, %Actor{} = actor} ->
        result =
          %{"id" => actor.id, "name" => actor.name, "as" => actor.id}
          |> put("instructions", actor.instructions)

        {:ok, result,
         text:
           "You act as #{actor.name} now. Pass \"as\": #{inspect(actor.id)} to every tool." <>
             if(actor.instructions, do: "\n\n" <> actor.instructions, else: "")}

      _ ->
        {:error, "You may not act as #{id}. list_actors says who you may act as."}
    end
  end

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)
end
