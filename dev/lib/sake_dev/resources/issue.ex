defmodule SakeDev.Resources.Issue do
  @moduledoc false
  use Sake.Resource,
    uri: "issue://{id}",
    name: "issue",
    title: "An issue",
    mime_type: "application/json",
    scope: "issues:read",
    subscribe: true

  @issues %{
    "1" => %{"id" => "1", "title" => "Login fails on Safari"},
    "2" => %{"id" => "2", "title" => "Export is slow"}
  }

  @impl true
  def read(%{id: id}, _ctx) do
    case Map.fetch(@issues, id) do
      {:ok, issue} -> {:ok, issue}
      :error -> {:error, :not_found}
    end
  end

  @impl true
  def list(_ctx),
    do: Enum.map(@issues, fn {id, i} -> %{uri: "issue://#{id}", name: i["title"]} end)

  @impl true
  def complete("id", partial, _ctx),
    do: {:ok, @issues |> Map.keys() |> Enum.filter(&String.starts_with?(&1, partial))}
end
