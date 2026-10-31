defmodule SakeDev.ConformanceServer do
  @moduledoc false
  # The fixture server the official MCP conformance suite runs against
  # (`/open/mcp` in `SakeDev.Router`, see `conformance/run.sh`). Every
  # `test_*` tool, resource, and prompt here (and the tasks extension's
  # fixtures, `greet` to `multi_input`) exists only to satisfy one
  # scenario's "Server Implementation Requirements" — it is not an example
  # of how to write a Sake server; see `SakeDev.Server` for that.
  use Sake.Server,
    name: "sake-conformance",
    version: Sake.version(),
    instructions: "Fixtures for the official MCP conformance suite."

  alias SakeDev.Conformance.{Prompts, Resources, Skills, Tools}

  tools [
    Tools.TestSimpleText,
    Tools.TestImageContent,
    Tools.TestAudioContent,
    Tools.TestEmbeddedResource,
    Tools.TestMultipleContentTypes,
    Tools.TestToolWithLogging,
    Tools.TestErrorHandling,
    Tools.TestToolWithProgress,
    Tools.TestReconnection,
    Tools.TestElicitation,
    Tools.TestElicitationSep1034Defaults,
    Tools.TestElicitationSep1330Enums,
    Tools.JsonSchema202012Tool,
    Tools.TestHeaderParam,
    Tools.TestStreamingElicitation,
    Tools.TestLoggingTool,
    Tools.TestTriggerToolChange,
    Tools.TestTriggerPromptChange,
    Tools.TestSampling,
    Tools.TestInputRequiredResultElicitation,
    Tools.TestInputRequiredResultSampling,
    Tools.TestInputRequiredResultListRoots,
    Tools.TestInputRequiredResultRequestState,
    Tools.TestInputRequiredResultMultipleInputs,
    Tools.TestInputRequiredResultMultiRound,
    Tools.TestInputRequiredResultTamperedState,
    Tools.TestInputRequiredResultCapabilities,
    Tools.TestMissingCapability,
    Tools.Greet,
    Tools.SlowCompute,
    Tools.FailingJob,
    Tools.ProtocolErrorJob,
    Tools.ConfirmDelete,
    Tools.MultiInput,
    Tools.TestToolWithTask
  ]

  resources [
    Resources.TestStaticText,
    Resources.TestStaticBinary,
    Resources.TestTemplate,
    Resources.TestWatched
  ]

  prompts [
    Prompts.TestSimplePrompt,
    Prompts.TestPromptWithArguments,
    Prompts.TestPromptWithEmbeddedResource,
    Prompts.TestPromptWithImage,
    Prompts.TestInputRequiredResultPrompt
  ]

  skills [Skills.PdfProcessing]
end
