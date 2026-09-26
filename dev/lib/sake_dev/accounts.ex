defmodule SakeDev.Accounts do
  @moduledoc false
  # A fixed set of people for the development server and the tests.

  @people %{
    "u1" => %{id: "u1", name: "Ana Lima", email: "ana@example.com", password: "secret"},
    "u2" => %{id: "u2", name: "Bo Chen", email: "bo@example.com", password: "secret"}
  }

  def get(id), do: Map.fetch(@people, id)

  def authenticate(email, password) do
    case Enum.find(@people, fn {_, p} -> p.email == email and p.password == password end) do
      {_, person} -> {:ok, person}
      nil -> :error
    end
  end
end
