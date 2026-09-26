defmodule Sake.Auth.ClientsTest do
  use SakeTest.AuthCase, async: false

  alias Sake.Auth.{Clients, Redirect}

  test "registered public and confidential clients", %{config: config} do
    assert {:ok,
            %{kind: :registered, token_endpoint_auth_method: "none", id: "rc_" <> _} = client,
            nil} =
             Clients.create(config, %{name: "CLI", redirect_uris: ["http://localhost:3000/cb"]})

    assert {:ok, ^client} = Clients.get(config, client.id)

    assert {:ok, %{token_endpoint_auth_method: "client_secret_basic", secret_hash: hash}, secret} =
             Clients.create(config, %{
               name: "Web",
               redirect_uris: ["https://app.example/cb"],
               confidential: true
             })

    assert is_binary(secret) and hash == Sake.Auth.Tokens.hash(secret)
    assert length(Clients.list(config)) == 2
    assert :ok = Clients.delete(config, client.id)
    assert :error = Clients.get(config, client.id)
  end

  test "redirect URI rules", %{config: config} do
    assert {:error, %{redirect_uris: "must be https or loopback http URLs"}} =
             Clients.create(config, %{name: "x", redirect_uris: ["http://example.com/cb"]})

    assert {:error, %{redirect_uris: "must not be empty"}} =
             Clients.create(config, %{name: "x", redirect_uris: []})

    assert {:error, %{name: "must be 1 to 100 characters"}} =
             Clients.create(config, %{name: "", redirect_uris: ["https://a.example/cb"]})

    assert Redirect.valid?("https://app.example/cb")
    assert Redirect.valid?("http://127.0.0.1:3000/cb")
    assert Redirect.valid?("http://[::1]:3000/cb")
    assert Redirect.valid?("http://localhost/cb")
    refute Redirect.valid?("http://app.example/cb")
    refute Redirect.valid?("https://app.example/cb#frag")
    refute Redirect.valid?("javascript:alert(1)")

    assert Redirect.matches?(["http://127.0.0.1:3000/cb"], "http://127.0.0.1:51234/cb")
    assert Redirect.matches?(["http://localhost:3000/cb"], "http://localhost:4000/cb")
    refute Redirect.matches?(["http://127.0.0.1:3000/cb"], "http://127.0.0.1:3000/other")
    refute Redirect.matches?(["https://app.example/cb"], "https://app.example/cb/")
    refute Redirect.matches?(["https://app.example/cb"], "https://app.example:444/cb")

    assert Redirect.matches?(
             ["https://app.example/cb", "https://b.example/cb"],
             "https://b.example/cb"
           )
  end
end
