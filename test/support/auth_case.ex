defmodule SakeTest.AuthCase do
  @moduledoc false
  # Starts a Sake supervisor with the ETS store and the dev subject for one test.
  use ExUnit.CaseTemplate
  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      import SakeTest.AuthCase
    end
  end

  setup tags do
    overrides = tags[:auth] || []

    store =
      if tags[:store] == :ecto do
        :ok = Sandbox.checkout(SakeTest.Repo)
        Sandbox.mode(SakeTest.Repo, {:shared, self()})
        {Sake.Auth.Store.Ecto, repo: SakeTest.Repo}
      else
        {Sake.Auth.Store.ETS, []}
      end

    auth =
      Keyword.merge(
        [
          subject: SakeDev.Subject,
          issuer: "http://www.example.com",
          allow_insecure: true,
          servers: [SakeDev.Server],
          resources: ["/mcp", "/:org/mcp"],
          store: store
        ],
        overrides
      )

    # The test helper already runs the streams registry; start only the auth part.
    pid =
      start_supervised!(
        {Sake,
         auth: auth, secret_key_base: SakeTest.ModernClient.secret(), streams: false, tasks: false}
      )

    %{config: Sake.Auth.config(), sake: pid}
  end

  @doc "Creates a registered public client with one loopback redirect URI."
  def public_client(config, attrs \\ %{}) do
    {:ok, client, nil} =
      Sake.Auth.Clients.create(
        config,
        Map.merge(%{name: "Test CLI", redirect_uris: ["http://127.0.0.1:9000/callback"]}, attrs)
      )

    client
  end

  @doc "Issues a token pair for tests; returns `{access_token_string, refresh_token_string, %{access: t, refresh: t}}`."
  def issue(config, attrs) do
    Sake.Auth.Tokens.issue_pair(
      config,
      Map.merge(
        %{
          client_id: "c",
          subject_id: "u1",
          scopes: [],
          resource: "http://www.example.com/mcp",
          family_id: Sake.Auth.Tokens.hash("code")
        },
        attrs
      )
    )
  end
end
