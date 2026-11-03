defmodule Sake.Actors.Actor do
  @moduledoc """
  An identity a principal may act as (`Sake.Actors`): one of their agents,
  a persona, an organization's bot.

    * `:id` — what a client passes as `as` to act as it. A string, unique
      among the actors of a principal.
    * `:name` — what the model and people see.
    * `:description` — optional: what the actor is for, in the list.
    * `:instructions` — optional: the actor's persona, which `act_as`
      returns for the model to follow while it acts as it.
    * `:data` — anything of the host's (its agent record, say), for the
      components that read `ctx.actor`. It is never sent to a client.
  """

  @enforce_keys [:id, :name]
  defstruct [:id, :name, :description, :instructions, :data]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          description: String.t() | nil,
          instructions: String.t() | nil,
          data: term()
        }

  @doc false
  def to_wire(%__MODULE__{} = actor, default?) do
    %{"id" => actor.id, "name" => actor.name, "default" => default?}
    |> put("description", actor.description)
  end

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)
end
