defmodule SakeDev.Subject do
  @moduledoc false
  @behaviour Sake.Auth.Subject

  @impl true
  def from_conn(conn) do
    with id when is_binary(id) <- Plug.Conn.get_session(conn, :user_id),
         {:ok, person} <- SakeDev.Accounts.get(id) do
      {:ok, person}
    else
      _ -> :error
    end
  end

  @impl true
  def id(%{id: id}), do: id

  @impl true
  def fetch(id), do: SakeDev.Accounts.get(id)

  @impl true
  def display(%{name: name, email: email}), do: "#{name} (#{email})"
end
