defmodule SakeDev.Conformance.Fixtures do
  @moduledoc false
  # Shared binary fixtures for the conformance tools and resources: a 1x1
  # red pixel PNG and an empty (header-only) WAV file.

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
       )

  @wav <<
    "RIFF"::binary,
    36::little-32,
    "WAVE"::binary,
    "fmt "::binary,
    16::little-32,
    1::little-16,
    1::little-16,
    8_000::little-32,
    8_000::little-32,
    1::little-16,
    8::little-16,
    "data"::binary,
    0::little-32
  >>

  def png, do: @png
  def wav, do: @wav
end
