defmodule SakeTest.TenantSubject do
  @moduledoc false
  # The development subject, plus a tenant rule: a person may authorize a
  # client only for the `acme` organization's endpoint.
  @behaviour Sake.Auth.Subject

  @impl true
  defdelegate from_conn(conn), to: SakeDev.Subject
  @impl true
  defdelegate id(person), to: SakeDev.Subject
  @impl true
  defdelegate fetch(id), to: SakeDev.Subject
  @impl true
  defdelegate display(person), to: SakeDev.Subject

  @impl true
  def authorize_resource?(_person, resource),
    do: URI.parse(resource).path |> String.split("/", trim: true) |> hd() == "acme"
end
