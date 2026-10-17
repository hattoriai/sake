defmodule Sake.Auth.WellKnown do
  @moduledoc """
  Serves `/.well-known/oauth-protected-resource` (also under the endpoint's
  path) and `/.well-known/oauth-authorization-server`. The protected
  resource metadata of an endpoint on an external authorization server
  (`Sake.Auth.External`) names that server; the authorization server
  metadata is only `Sake.Auth`'s, and so is
  `/.well-known/openid-configuration`, OpenID Connect Discovery's, which
  is there with `openid:` alone. Mount at the root:

      forward "/.well-known", Sake.Auth.WellKnown

  or `sake_well_known()` in a Phoenix router.
  """
  @behaviour Plug
  import Plug.Conn
  require Logger

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

  def call(%{method: "GET", path_info: ["openid-configuration"]} = conn, _opts),
    do: openid_configuration(conn)

  def call(%{method: "GET", path_info: [".well-known", "openid-configuration"]} = conn, _opts),
    do: openid_configuration(conn)

  def call(conn, _opts), do: send_resp(conn, 404, "")

  # The endpoint at the path names its authorization server: the
  # external one whose `resources:` cover it, else Sake's own. With
  # neither, there is no protected resource there.
  defp protected_resource(conn, rest) do
    suffix = if rest == [], do: "", else: "/" <> Enum.join(rest, "/")

    case External.for_path(suffix) || Sake.Auth.configured() do
      nil ->
        send_resp(conn, 404, "")

      config ->
        origin = Resource.origin(conn, config)
        warn_origin(conn, origin)
        json(conn, Metadata.protected_resource(config, origin <> suffix))
    end
  end

  # A request that arrives with another origin than the one the metadata
  # names has come through a proxy the app does not rewrite for
  # (`Plug.RewriteOn`). Sake names the right one either way, but other
  # URLs the app builds from the request will not be, so it says so,
  # once per node.
  defp warn_origin(conn, origin) do
    request_origin = Resource.origin(conn)

    if request_origin != origin and not :persistent_term.get({__MODULE__, :warned}, false) do
      :persistent_term.put({__MODULE__, :warned}, true)

      Logger.warning(
        "Sake names #{origin} as the resource's origin, but the request arrived at " <>
          "#{request_origin}. Behind a proxy, rewrite the host and scheme from its headers " <>
          "(Plug.RewriteOn); see \"Behind a proxy\" in the security guide."
      )
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

  # Only with `openid:`: without it, Sake is no OpenID Provider.
  defp openid_configuration(conn) do
    with %{} = config <- Sake.Auth.configured(),
         %{} = metadata <- Metadata.openid_configuration(config) do
      json(conn, metadata)
    else
      nil -> send_resp(conn, 404, "")
    end
  end

  defp json(conn, body) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "public, max-age=3600")
    |> send_resp(200, JSON.encode!(body))
  end
end
