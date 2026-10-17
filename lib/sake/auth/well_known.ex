defmodule Sake.Auth.WellKnown do
  @moduledoc """
  Serves `/.well-known/oauth-protected-resource` (also under the endpoint's
  path) and `/.well-known/oauth-authorization-server`. The protected
  resource metadata of an endpoint on an external authorization server
  (`Sake.Auth.External`) names that server; the authorization server
  metadata is only `Sake.Auth`'s. Mount at the root:

      forward "/.well-known", Sake.Auth.WellKnown

  or `sake_well_known()` in a Phoenix router.
  """
  @behaviour Plug
  import Plug.Conn

  alias Sake.Auth.{External, Metadata, Resource}

  # The adapter: it routes the request, names the configuration and the
  # resource, and serves what `Sake.Auth.Metadata` builds.

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{method: "GET", path_info: ["oauth-protected-resource" | rest]} = conn, _opts),
    do: protected_resource(conn, rest)

  def call(
        %{method: "GET", path_info: [".well-known", "oauth-protected-resource" | rest]} = conn,
        _opts
      ),
      do: protected_resource(conn, rest)

  def call(%{method: "GET", path_info: ["oauth-authorization-server"]} = conn, _opts),
    do: authorization_server(conn)

  def call(
        %{method: "GET", path_info: [".well-known", "oauth-authorization-server"]} = conn,
        _opts
      ),
      do: authorization_server(conn)

  def call(conn, _opts), do: send_resp(conn, 404, "")

  # The endpoint at the path names its authorization server: the
  # external one whose `resources:` cover it, else Sake's own. With
  # neither, there is no protected resource there.
  defp protected_resource(conn, rest) do
    suffix = if rest == [], do: "", else: "/" <> Enum.join(rest, "/")

    case External.for_path(suffix) || Sake.Auth.configured() do
      nil -> send_resp(conn, 404, "")
      config -> json(conn, Metadata.protected_resource(config, Resource.origin(conn) <> suffix))
    end
  end

  # Only Sake's own authorization server has metadata here; an external
  # one serves its own.
  defp authorization_server(conn) do
    case Sake.Auth.configured() do
      nil -> send_resp(conn, 404, "")
      config -> json(conn, Metadata.authorization_server(config))
    end
  end

  defp json(conn, body) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "public, max-age=3600")
    |> send_resp(200, JSON.encode!(body))
  end
end
