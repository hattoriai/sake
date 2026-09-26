defmodule Sake.Auth do
  @moduledoc """
  Authorization for a Sake endpoint: the host app is the OAuth 2.1
  authorization server, and the endpoint is the resource server.

  Configure it on the `Sake` child (see `Sake.child_spec/1`) and mount the
  routes with `Sake.Router` (Phoenix) or `Sake.Auth.RouterPlug` (Plug).
  """

  alias Sake.Auth.Config

  @spec config() :: Config.t()
  def config do
    :persistent_term.get({Sake, :auth}, nil) ||
      raise "Sake authorization is not configured: start {Sake, auth: [...]}"
  end

  @doc false
  def store(%Config{store: {module, _}, store_state: state}), do: {module, state}
end
