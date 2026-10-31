defmodule Sake.Client.Page do
  @moduledoc """
  One page of a list: what `Sake.Client.list_tools_page/2` and its kin
  return.

    * `entries` — the page's entries: `Sake.Tool.Spec`s for tools, the
      server's maps for the other lists.
    * `next_cursor` — the cursor of the next page, for the next call, or
      `nil` on the last page.
    * `cache` — the page's `Sake.Client.CacheInfo` (`ttlMs`, `cacheScope`).
    * `meta` — the result's `_meta`.
  """

  alias Sake.Client.CacheInfo

  @type t :: %__MODULE__{
          entries: [term()],
          next_cursor: String.t() | nil,
          cache: CacheInfo.t(),
          meta: map()
        }

  defstruct [:next_cursor, :cache, entries: [], meta: %{}]

  @doc false
  @spec from_result(map(), String.t()) :: t()
  def from_result(result, key) do
    %__MODULE__{
      entries: List.wrap(result[key]),
      next_cursor: if(is_binary(result["nextCursor"]), do: result["nextCursor"]),
      cache: CacheInfo.from_result(result),
      meta: result["_meta"] || %{}
    }
  end
end
