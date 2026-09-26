defmodule Sake.Auth.PKCE do
  @moduledoc false

  @doc "Whether `S256(verifier)` equals `challenge`. Verifiers are 43 to 128 characters."
  @spec verify(term(), term()) :: boolean()
  def verify(challenge, verifier)
      when is_binary(challenge) and is_binary(verifier) and byte_size(verifier) in 43..128 do
    expected = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    Plug.Crypto.secure_compare(expected, challenge)
  end

  def verify(_, _), do: false
end
