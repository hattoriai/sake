defmodule SakeDev.Conformance.Skills.PdfProcessing do
  @moduledoc false
  # The skill the Skills extension's scenarios (sep-2640-*) discover:
  # a SKILL.md, supporting files, and a subdirectory for
  # resources/directory/read to descend into.
  use Sake.Skill, dir: "pdf-processing"
end
