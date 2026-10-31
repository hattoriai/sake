defmodule Sake.Client.ReadResult do
  @moduledoc """
  The result of `Sake.Client.read_resource_result/2`: the resource's
  `contents` (as `Sake.Content` embedded resources, as
  `Sake.Client.read_resource/2` returns them), its `cache` (a
  `Sake.Client.CacheInfo`: the read's `ttlMs` and `cacheScope`), and the
  result's `meta`.
  """

  alias Sake.Client.CacheInfo

  @type t :: %__MODULE__{
          contents: [Sake.Content.t()],
          cache: CacheInfo.t(),
          meta: map()
        }

  defstruct [:cache, contents: [], meta: %{}]
end
