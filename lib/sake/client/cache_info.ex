defmodule Sake.Client.CacheInfo do
  @moduledoc """
  What a result says about caching it (MCP 2026-07-28): how long it stays
  fresh, and who may share it. `Sake.Client.Page` and
  `Sake.Client.ReadResult` carry one.

    * `ttl_ms` — the server's `ttlMs`: how long, from `fetched_at`, the
      result may be used without asking again. `0` means not at all.
      `nil` when the server gave none (every legacy server): how long to
      keep it is then the caller's own policy.
    * `scope` — the server's `cacheScope`: `:public` (the same for every
      client of the server), `:private` (for this client's principal
      alone, never to be shared with another), or `nil` when it gave
      none. An unknown value is taken as `:private`.
    * `fetched_at` — `System.monotonic_time(:millisecond)` when the
      answer arrived.

  Sake keeps no cache of its own for the client (`Sake.Proxy` keeps one
  for the catalogs it forwards): see "Large catalogs and caching" in
  `guides/client.md` for a policy built on these fields.
  """

  @type scope :: :public | :private | nil
  @type t :: %__MODULE__{
          ttl_ms: non_neg_integer() | nil,
          scope: scope(),
          fetched_at: integer()
        }

  defstruct [:ttl_ms, :scope, :fetched_at]

  @doc false
  @spec from_result(map()) :: t()
  def from_result(result) do
    %__MODULE__{
      ttl_ms: ttl(result["ttlMs"]),
      scope: scope(result["cacheScope"]),
      fetched_at: System.monotonic_time(:millisecond)
    }
  end

  defp ttl(ms) when is_integer(ms) and ms >= 0, do: ms
  defp ttl(_), do: nil

  defp scope(nil), do: nil
  defp scope("public"), do: :public
  defp scope(_private_or_unknown), do: :private

  @doc """
  Whether the result may still be used without asking the server again:
  its `ttl_ms` has not run out (at `now`, a monotonic time in ms). Never
  for a `ttl_ms` of `0`, nor for one the server did not give (`nil`),
  which `fresh?/2` cannot judge: that is the caller's policy.
  """
  @spec fresh?(t() | %{cache: t()}, integer()) :: boolean()
  def fresh?(info, now \\ System.monotonic_time(:millisecond))

  def fresh?(%{cache: %__MODULE__{} = info}, now), do: fresh?(info, now)

  def fresh?(%__MODULE__{ttl_ms: ttl, fetched_at: at}, now) when is_integer(ttl) and ttl > 0,
    do: now < at + ttl

  def fresh?(%__MODULE__{}, _now), do: false
end
