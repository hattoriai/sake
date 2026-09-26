defmodule SakeDev.Tools.Confirm do
  @moduledoc false
  use Sake.Tool, name: "confirm", description: "Asks for a name, then greets"
  arg :greeting, :string, default: "Hello"

  @impl true
  def execute(%{greeting: greeting}, ctx) do
    case Sake.Elicit.form(ctx, :who, "Who should be greeted?", %{
           "type" => "object",
           "properties" => %{"name" => %{"type" => "string"}},
           "required" => ["name"]
         }) do
      {:ok, %{"name" => name}} -> {:ok, "#{greeting}, #{name}!"}
      :decline -> {:ok, "No greeting then."}
      :cancel -> {:error, "Cancelled."}
      {:error, :unsupported} -> {:error, "This tool needs a client that supports elicitation."}
    end
  end
end
