defmodule Sake.Server.Cursor do
  @moduledoc false

  @salt "sake.cursor"

  @spec encode(binary(), non_neg_integer()) :: String.t()
  def encode(secret, offset), do: Plug.Crypto.sign(secret, @salt, offset)

  @spec decode(binary(), term()) :: {:ok, non_neg_integer()} | :error
  def decode(secret, cursor) when is_binary(cursor) do
    case Plug.Crypto.verify(secret, @salt, cursor, max_age: 3_600) do
      {:ok, offset} when is_integer(offset) and offset >= 0 -> {:ok, offset}
      _ -> :error
    end
  end

  def decode(_, _), do: :error
end
