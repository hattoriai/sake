defmodule Sake.Client.Auth.Device do
  @moduledoc """
  The interactive step of the device authorization grant (RFC 8628),
  `grant: :device` in `Sake.Client.Auth`: the client shows the person a
  user code and where to enter it, on any device, and polls the token
  endpoint until they decide there.

  `prompt/1` is the default `:device_prompt`: it logs the code and the
  URL, as `Sake.Client.Auth.Browser` logs the authorization URL when it
  cannot open a browser. A CLI shows them its own way:

      auth: [
        grant: :device,
        device_prompt: fn %{user_code: code, verification_uri: uri} ->
          IO.puts("Open \#{uri} and enter \#{code}")
        end
      ]

  The function receives `user_code`, `verification_uri`,
  `verification_uri_complete` (the URL with the code in it, for a link
  or a QR code; nil when the server gives none) and `expires_in`, in
  seconds. What it returns is ignored.
  """

  require Logger

  @doc "Logs the user code and the verification URL."
  @spec prompt(map()) :: :ok
  def prompt(%{user_code: code, verification_uri: uri} = info) do
    link =
      case info[:verification_uri_complete] do
        complete when is_binary(complete) -> " (or open #{complete})"
        _ -> ""
      end

    Logger.warning("Sake.Client: to authorize, open #{uri} and enter the code #{code}#{link}")
  end
end
