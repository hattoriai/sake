defmodule Sake.Actors.ListActors do
  @moduledoc false
  # `list_actors`, on a server with `actors` (`Sake.Actors`).

  use Sake.Tool,
    name: "list_actors",
    title: "Who you may act as",
    description:
      "Lists the identities you may act as here, and which one a call without `as` acts as. " <>
        "Call act_as with one's id to take on its persona, then pass that id as `as` to every tool.",
    annotations: [read_only: true, idempotent: true]

  alias Sake.Actors
  alias Sake.Actors.Actor

  @impl true
  def execute(_args, ctx) do
    module = Actors.module(ctx)
    default = Actors.default(module, ctx)

    actors =
      for actor <- Actors.list(module, ctx),
          do: Actor.to_wire(actor, match?(%Actor{id: id} when id == actor.id, default))

    {:ok, %{"actors" => actors, "default" => default && default.id}}
  end
end
