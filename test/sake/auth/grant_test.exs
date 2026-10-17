defmodule Sake.Auth.GrantTest.Subject do
  @moduledoc false
  # The development subject, with Bo (u2) holding `issues:read` only and
  # nobody allowed the `/locked/mcp` endpoint.
  @behaviour Sake.Auth.Subject

  @impl true
  defdelegate from_conn(conn), to: SakeDev.Subject
  @impl true
  defdelegate id(person), to: SakeDev.Subject
  @impl true
  defdelegate fetch(id), to: SakeDev.Subject
  @impl true
  defdelegate display(person), to: SakeDev.Subject

  @impl true
  def authorize_resource?(_person, resource), do: URI.parse(resource).path != "/locked/mcp"

  @impl true
  def scopes_for(%{id: "u2"}, _resource), do: ["issues:read"]
  def scopes_for(_person, _resource), do: :all
end

defmodule Sake.Auth.GrantTest do
  # The decision after login, without HTTP: a request, a principal, and
  # the store.
  use SakeTest.AuthCase, async: false

  alias Sake.Auth.{AuthorizationRequest, Grant, Tokens}

  @moduletag auth: [subject: Sake.Auth.GrantTest.Subject]

  @challenge "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
  @resource "http://www.example.com/mcp"

  defp request(client, attrs \\ %{}) do
    struct!(
      %AuthorizationRequest{
        client_id: client.id,
        redirect_uri: hd(client.redirect_uris),
        state: "xyz",
        code_challenge: @challenge,
        scopes: ["issues:read", "issues:write"],
        resource: @resource
      },
      attrs
    )
  end

  defp person(id) do
    {:ok, person} = SakeDev.Accounts.get(id)
    person
  end

  test "without a remembered consent, the consent page's assigns", %{config: config} do
    client = public_client(config)
    request = request(client)

    assert {:consent, assigns} = Grant.decide(config, client, request, person("u1"))

    assert %{
             client_name: "Test CLI",
             client_host: nil,
             redirect_host: "127.0.0.1:9000",
             loopback?: true,
             subject_display: "Ana Lima" <> _,
             scopes: [{"issues:read", _}, {"issues:write", _}],
             resource: @resource,
             request: ^request,
             issuer_name: "www.example.com"
           } = assigns

    refute Map.has_key?(assigns, :action)
    refute Map.has_key?(assigns, :csrf_token)
  end

  test "the scopes are narrowed to those the person may hold", %{config: config} do
    client = public_client(config)

    assert {:consent, %{request: %{scopes: ["issues:read"]}, scopes: [{"issues:read", _}]}} =
             Grant.decide(config, client, request(client), person("u2"))

    assert {:error, "access_denied", "You may not hold any of the requested scopes"} =
             Grant.decide(config, client, request(client, scopes: ["issues:write"]), person("u2"))

    # A request for no scope at all is not refused for it.
    assert {:consent, %{request: %{scopes: []}}} =
             Grant.decide(config, client, request(client, scopes: []), person("u2"))
  end

  test "a resource the person may not authorize is refused", %{config: config} do
    client = public_client(config)
    request = request(client, resource: "http://www.example.com/locked/mcp")

    assert {:error, "access_denied", "You may not authorize this resource"} =
             Grant.decide(config, client, request, person("u1"))
  end

  test "approve/3 issues the code and remembers the consent; then decide/4 issues at once", %{
    config: config
  } do
    client = public_client(config)
    {module, state} = Sake.Auth.store(config)
    request = request(client, scopes: ["issues:read"])

    assert {:ok, code} = Grant.approve(config, request, "u1")

    assert {:ok, %{subject_id: "u1", scopes: ["issues:read"], code_challenge: @challenge}} =
             module.consume_code(state, Tokens.hash(code))

    assert {:ok, %{scopes: ["issues:read"]}} =
             module.get_consent(state, "u1", client.id, @resource)

    assert {:issue, ^request} = Grant.decide(config, client, request, person("u1"))

    # The consent covers these scopes only: asking for more asks again.
    assert {:consent, _} = Grant.decide(config, client, request(client), person("u1"))

    assert {:ok, code} = Grant.issue(config, request, "u1")
    assert {:ok, %{subject_id: "u1"}} = module.consume_code(state, Tokens.hash(code))
  end

  @tag auth: [subject: Sake.Auth.GrantTest.Subject, remember_consent: false]
  test "without remember_consent, nothing is remembered and the person is always asked", %{
    config: config
  } do
    client = public_client(config)
    request = request(client, scopes: ["issues:read"])
    {module, state} = Sake.Auth.store(config)

    assert {:ok, _code} = Grant.approve(config, request, "u1")
    assert :error = module.get_consent(state, "u1", client.id, @resource)
    assert {:consent, _} = Grant.decide(config, client, request, person("u1"))
  end
end
