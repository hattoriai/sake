defmodule SakeDev.Conformance.Tools.TestElicitation do
  @moduledoc false
  use Sake.Tool, name: "test_elicitation", description: "Asks the client for input"

  arg :message, :string, required: true

  @impl true
  def execute(%{message: message}, ctx) do
    schema = %{
      "type" => "object",
      "properties" => %{
        "username" => %{"type" => "string", "description" => "User's response"},
        "email" => %{"type" => "string", "description" => "User's email address"}
      },
      "required" => ["username", "email"]
    }

    case Sake.Elicit.form(ctx, :test_elicitation, message, schema) do
      {:ok, content} -> {:ok, "User response: action=accept, content=#{inspect(content)}"}
      :decline -> {:ok, "User response: action=decline"}
      :cancel -> {:ok, "User response: action=cancel"}
      {:error, :unsupported} -> {:error, "This tool needs a client that supports elicitation."}
    end
  end
end
