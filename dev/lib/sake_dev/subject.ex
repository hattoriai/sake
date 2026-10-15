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

  # A machine client acts as itself: tools see the client, not a person.
  @impl true
  def client_principal(client), do: {:ok, %{id: client.id, name: client.name, client: true}}

  # A JWT grant from a trusted issuer stands for the person with its
  # verified email address.
  @impl true
  def assertion_principal(%{"email" => email}, _issuer) when is_binary(email),
    do: SakeDev.Accounts.by_email(email)

  def assertion_principal(_claims, _issuer), do: :error
end
