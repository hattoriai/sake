defmodule SakeDev.Issues do
  @moduledoc false
  # The issues the issue board shows.

  @issues [
    %{
      "id" => "1",
      "title" => "Login fails on Safari",
      "state" => "open",
      "body" => "Signing in with Safari 17 loops back to the login page."
    },
    %{
      "id" => "2",
      "title" => "Export is slow",
      "state" => "open",
      "body" => "Exporting more than a thousand issues takes over a minute."
    },
    %{
      "id" => "3",
      "title" => "Dark mode for the settings page",
      "state" => "closed",
      "body" => "The settings page now follows the system theme."
    }
  ]

  def all, do: @issues

  def fetch(id) do
    case Enum.find(@issues, &(&1["id"] == id)) do
      nil -> :error
      issue -> {:ok, issue}
    end
  end
end
