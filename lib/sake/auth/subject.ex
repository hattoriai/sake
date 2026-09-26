defmodule Sake.Auth.Subject do
  @moduledoc """
  How Sake finds the person behind a request. The host implements it:

      defmodule MyAppWeb.MCPSubject do
        @behaviour Sake.Auth.Subject
        def from_conn(conn), do: with(%{user: user} <- conn.assigns[:current_scope], do: {:ok, user}, else: (_ -> :error))
        def id(user), do: user.id
        def fetch(id), do: MyApp.Accounts.fetch_user(id)
        def display(user), do: user.email
      end

  Sake stores only the string ID.
  """

  @callback from_conn(Plug.Conn.t()) :: {:ok, term()} | :error
  @callback id(term()) :: String.t()
  @callback fetch(String.t()) :: {:ok, term()} | :error
  @callback display(term()) :: String.t()
end
