defmodule SakeDev.Conformance.Tools.TestTriggerPromptChange do
  @moduledoc false
  # server-stateless: the prompt-list counterpart of
  # `test_trigger_tool_change`.
  use Sake.Tool,
    name: "test_trigger_prompt_change",
    description: "Announces a change to the prompt list"

  @impl true
  def execute(%{}, ctx) do
    Sake.Server.notify_list_changed(ctx.server, :prompts)
    {:ok, "Prompt list change announced."}
  end
end
