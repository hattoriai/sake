defmodule Sake.Secret do
  @moduledoc false
  # The signing secret: the `secret:` option, else the running `Sake`
  # configuration, else `config :sake, :secret_key_base`.

  @spec resolve(term()) :: binary()
  def resolve(secret) when is_binary(secret) and byte_size(secret) >= 32, do: secret
  def resolve({m, f, a}), do: resolve(apply(m, f, a))
  def resolve(nil), do: fetch!()

  def resolve(_),
    do: raise(ArgumentError, "the Sake secret must be a binary of at least 32 bytes or {m, f, a}")

  @spec fetch!() :: binary()
  def fetch! do
    case :persistent_term.get({Sake, :secret_key_base}, nil) ||
           Application.get_env(:sake, :secret_key_base) do
      nil ->
        raise ArgumentError,
              "Sake needs a secret: pass secret: to Sake.Plug, start {Sake, secret_key_base: ...}, or set config :sake, :secret_key_base"

      secret ->
        resolve(secret)
    end
  end
end
