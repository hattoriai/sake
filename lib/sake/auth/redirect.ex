defmodule Sake.Auth.Redirect do
  @moduledoc false
  # Redirect URIs: https, or http on a loopback host. Matching is exact,
  # except that the port of a loopback URI may differ (RFC 8252 §7.3).

  @loopback ["127.0.0.1", "[::1]", "::1", "localhost"]

  @spec valid?(term()) :: boolean()
  def valid?(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: "https", host: host, userinfo: nil, fragment: nil}
      when is_binary(host) and host != "" ->
        true

      %URI{scheme: "http", host: host, userinfo: nil, fragment: nil} when host in @loopback ->
        true

      _ ->
        false
    end
  end

  def valid?(_), do: false

  @spec loopback?(String.t()) :: boolean()
  def loopback?(uri), do: match?(%URI{host: host} when host in @loopback, URI.parse(uri))

  @spec matches?([String.t()], term()) :: boolean()
  def matches?(registered, given) when is_binary(given) do
    Enum.any?(registered, fn r ->
      r == given or (loopback?(r) and loopback?(given) and same_but_port?(r, given))
    end)
  end

  def matches?(_, _), do: false

  defp same_but_port?(a, b) do
    # Not `%{URI.parse(a) | port: nil} == ...`: `URI.parse/1` also fills in
    # `authority`, which still carries the port and would defeat the
    # comparison. Compared field by field instead, everything except `port`
    # and `authority` — including `userinfo`, so a URI carrying credentials
    # never matches one that does not.
    a = URI.parse(a)
    b = URI.parse(b)

    a.scheme == b.scheme and a.userinfo == b.userinfo and a.host == b.host and a.path == b.path and
      a.query == b.query and a.fragment == b.fragment
  end
end
