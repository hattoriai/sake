defmodule Sake.Client.Auth.Store do
  @moduledoc """
  Keeps a client's tokens and dynamic registrations across sessions. Pass
  `store: {module, arg}` in `Sake.Client.connect/2`'s `auth:` options;
  `arg` is handed to every callback.

  Three kinds of keys:

    * `{:token, url}` — the token for one MCP endpoint (its canonical URL),
      with its refresh token, expiry, scopes, and the authorization server
      and client it was issued by and to.
    * `{:client, issuer}` — a dynamic registration (client id and secret)
      with one authorization server. Registrations are bound to their
      server: one is never presented to another.
    * `{:idp, issuer}` — the enterprise identity provider's refresh token
      from a SAML exchange (`grant: :enterprise` with `saml_assertion:`),
      with its expiry and the client at the provider it was issued to. It
      stands for the person's single sign-on until it expires: guard it
      like the tokens.

  Values are maps with string keys and JSON values, so a store can write
  them as JSON. They hold credentials: keep them where only the person
  running the client can read them (OAuth 2.1 §7.1), such as the system
  keychain or a file only they can read.

      defmodule MyApp.TokenStore do
        @behaviour Sake.Client.Auth.Store

        @impl true
        def fetch(dir, key) do
          case File.read(path(dir, key)) do
            {:ok, json} -> {:ok, JSON.decode!(json)}
            {:error, _} -> :error
          end
        end

        @impl true
        def put(dir, key, value) do
          File.write!(path(dir, key), JSON.encode!(value))
          File.chmod!(path(dir, key), 0o600)
        end

        defp path(dir, key),
          do: Path.join(dir, Base.url_encode64(:erlang.term_to_binary(key), padding: false))
      end
  """

  @type key ::
          {:token, url :: String.t()}
          | {:client, issuer :: String.t()}
          | {:idp, issuer :: String.t()}

  @callback fetch(arg :: term(), key()) :: {:ok, map()} | :error
  @callback put(arg :: term(), key(), map()) :: :ok
end
