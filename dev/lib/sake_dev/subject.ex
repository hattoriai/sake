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

  # OpenID Connect: the person's name for `profile`, their address for
  # `email`, at the userinfo endpoint.
  @impl true
  def claims(person, scopes) do
    %{}
    |> Map.merge(if "profile" in scopes, do: %{"name" => person.name}, else: %{})
    |> Map.merge(
      if "email" in scopes,
        do: %{"email" => person.email, "email_verified" => true},
        else: %{}
    )
  end

  # A machine client acts as itself: tools see the client, not a person.
  @impl true
  def client_principal(client), do: {:ok, %{id: client.id, name: client.name, client: true}}

  # A JWT grant from a trusted issuer stands for the person with its
  # verified email address.
  @impl true
  def assertion_principal(%{"email" => email}, _issuer) when is_binary(email),
    do: SakeDev.Accounts.by_email(email)

  def assertion_principal(_claims, _issuer), do: :error

  # How the person signed in, as the login form recorded it: "pwd" with a
  # password, "mfa" with the one-time code as well (RFC 9470).
  @impl true
  def authentication(conn) do
    %{
      acr: Plug.Conn.get_session(conn, :acr),
      auth_time:
        case Plug.Conn.get_session(conn, :auth_time) do
          at when is_integer(at) -> DateTime.from_unix!(at)
          _ -> nil
        end
    }
  end

  # Back to the login form, which asks for the one-time code when MFA is
  # asked for, and then to the page that sent the person there.
  @impl true
  def reauthenticate(conn, %{acr_values: acr_values}) do
    return_to = conn.request_path <> "?" <> conn.query_string
    mfa = if "mfa" in acr_values, do: %{"acr" => "mfa"}, else: %{}

    conn
    |> Plug.Conn.put_resp_header(
      "location",
      "/login?" <> URI.encode_query(Map.put(mfa, "return_to", return_to))
    )
    |> Plug.Conn.send_resp(302, "")
  end
end
