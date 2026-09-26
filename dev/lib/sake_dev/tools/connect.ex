defmodule SakeDev.Tools.Connect do
  @moduledoc false
  use Sake.Tool, name: "connect", description: "Sends the person to a page, then continues"

  @impl true
  def execute(%{}, ctx) do
    case Sake.Elicit.url(ctx, :page, "Open the page to continue", "https://example.com/connect") do
      :ok ->
        {:ok, "Connected."}

      :decline ->
        {:ok, "Not connected."}

      :cancel ->
        {:error, "Cancelled."}

      {:error, :unsupported} ->
        {:error, "This tool needs a client that supports URL elicitation."}
    end
  end
end
