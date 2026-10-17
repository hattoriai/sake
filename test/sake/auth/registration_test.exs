defmodule Sake.Auth.RegistrationTest do
  # Dynamic client registration, without HTTP: a decoded document in, the
  # registration response or an error code out.
  use SakeTest.AuthCase, async: false

  alias Sake.Auth.Registration

  test "registers a public client", %{config: config} do
    assert {:ok, %{"client_id" => "dc_" <> _ = id} = response} =
             Registration.register(config, %{
               "redirect_uris" => ["http://127.0.0.1:1/cb"],
               "client_name" => "CLI"
             })

    assert response["grant_types"] == ["authorization_code", "refresh_token"]
    assert response["token_endpoint_auth_method"] == "none"
    assert {:ok, %{name: "CLI"}} = Sake.Auth.Clients.get(config, id)
  end

  test "refuses a document it cannot accept", %{config: config} do
    for {doc, code} <- [
          {%{"redirect_uris" => []}, "invalid_redirect_uri"},
          {%{"redirect_uris" => ["http://127.0.0.1:1/cb"], "grant_types" => ["implicit"]},
           "invalid_client_metadata"},
          {%{
             "redirect_uris" => ["http://127.0.0.1:1/cb"],
             "token_endpoint_auth_method" => "client_secret_basic"
           }, "invalid_client_metadata"},
          {[1], "invalid_client_metadata"}
        ] do
      assert Registration.register(config, doc) == {:error, code}, inspect(doc)
    end
  end
end
