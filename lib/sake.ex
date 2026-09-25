defmodule Sake do
  @moduledoc """
  Sake is MCP for Elixir and Phoenix.

  See `Sake.Server` to expose tools, `Sake.Plug` to mount the endpoint,
  `Sake.Auth` to protect it with your own login, and `Sake.Client` to call
  other servers.
  """

  @version Mix.Project.config()[:version]

  @doc "The package version."
  @spec version() :: String.t()
  def version, do: @version
end
