defmodule Sake.Test.TokenStore do
  @moduledoc false
  # The one token of a `Sake.Test` client sent through a plug to a server
  # that takes DPoP-bound tokens only: handed to `Sake.Client.Auth` as its
  # stored token, so that every request carries a fresh proof for it.
  @behaviour Sake.Client.Auth.Store

  @impl true
  def fetch(token, {:token, _url}), do: {:ok, token}
  def fetch(_token, _key), do: :error

  @impl true
  def put(_token, _key, _value), do: :ok
end
