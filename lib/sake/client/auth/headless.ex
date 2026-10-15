defmodule Sake.Client.Auth.Headless do
  @moduledoc """
  Authorizes without a person: GETs the authorization URL, does not follow
  the redirect it answers with, and reads the authorization response from
  its `Location` header.

      Sake.Client.connect(url, auth: [authorize: &Sake.Client.Auth.Headless.authorize/1])

  Only for an authorization server that approves at once — a test server,
  the conformance suite's, or one that recognizes the caller from
  something passed in `req:` (a session cookie, say) — never for one that
  shows a login page or asks for consent.
  """

  @doc """
  Follows `url` once. The redirect must go to the request's own
  `redirect_uri`; its query parameters are the result. `opts`: `req:`,
  extra options for `Req.get/2`.
  """
  @spec authorize(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def authorize(url, opts \\ []) do
    redirect_uri = url |> URI.parse() |> Map.get(:query) |> Kernel.||("") |> URI.decode_query()

    request =
      [redirect: false, retry: false, decode_body: false] ++ Keyword.get(opts, :req, [])

    case Req.get(url, request) do
      {:ok, %Req.Response{status: status} = resp} when status in 300..399 ->
        case Req.Response.get_header(resp, "location") do
          [location | _] -> callback(location, redirect_uri["redirect_uri"])
          [] -> {:error, {:no_redirect, status}}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:no_redirect, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Anything but the redirect URI itself (a login page, an error page) is
  # not an authorization response.
  defp callback(location, redirect_uri) when is_binary(redirect_uri) do
    uri = URI.parse(location)

    if without_query(uri) == without_query(URI.parse(redirect_uri)),
      do: {:ok, URI.decode_query(uri.query || "")},
      else: {:error, {:unexpected_redirect, location}}
  end

  defp callback(location, _redirect_uri), do: {:error, {:unexpected_redirect, location}}

  defp without_query(uri), do: URI.to_string(%{uri | query: nil, fragment: nil})
end
