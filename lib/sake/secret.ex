defmodule Sake.Secret do
  @moduledoc false
  # The signing secret: the `secret:` option, else the running `Sake`
  # configuration, else `config :sake, :secret_key_base`. An `{m, f, a}`
  # is called when the secret is first needed, never when `Sake` starts:
  # it may name a process that starts after Sake (an endpoint's
  # `config/1`, which reads a table the endpoint creates).

  @doc "Raises unless `secret` is a binary of at least 32 bytes or `{m, f, a}`; returns it unresolved."
  @spec validate!(term()) :: binary() | {module(), atom(), list()}
  def validate!(secret) when is_binary(secret) and byte_size(secret) >= 32, do: secret
  def validate!({m, f, a} = secret) when is_atom(m) and is_atom(f) and is_list(a), do: secret

  def validate!(_),
    do: raise(ArgumentError, "the Sake secret must be a binary of at least 32 bytes or {m, f, a}")

  @spec resolve(term()) :: binary()
  def resolve(secret) when is_binary(secret) and byte_size(secret) >= 32, do: secret
  def resolve({m, f, a}), do: resolve(apply(m, f, a))
  def resolve(nil), do: fetch!()

  def resolve(_),
    do: raise(ArgumentError, "the Sake secret must be a binary of at least 32 bytes or {m, f, a}")

  @spec fetch!() :: binary()
  def fetch! do
    configured() ||
      raise ArgumentError,
            "Sake needs a secret: pass secret: to Sake.Plug, start {Sake, secret_key_base: ...}, or set config :sake, :secret_key_base"
  end

  # The running `Sake` configuration's secret, else the application
  # environment's, else nil.
  @spec configured() :: binary() | nil
  def configured do
    case unresolved() do
      nil -> nil
      secret -> resolve(secret)
    end
  end

  # The configured secret as given, an `{m, f, a}` not yet called, or nil.
  @spec unresolved() :: binary() | {module(), atom(), list()} | nil
  def unresolved do
    :persistent_term.get({Sake, :secret_key_base}, nil) ||
      Application.get_env(:sake, :secret_key_base)
  end
end
