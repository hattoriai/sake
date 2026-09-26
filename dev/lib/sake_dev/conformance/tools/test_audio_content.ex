defmodule SakeDev.Conformance.Tools.TestAudioContent do
  @moduledoc false
  use Sake.Tool, name: "test_audio_content", description: "Returns audio content"

  alias SakeDev.Conformance.Fixtures

  @impl true
  def execute(%{}, _ctx),
    do: {:ok, [Sake.Content.audio(Fixtures.wav(), "audio/wav")]}
end
