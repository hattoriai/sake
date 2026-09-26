defmodule SakeTest.StoreCases do
  @moduledoc "The `Sake.Auth.Store` behaviour tests, run against every store."

  defmacro __using__(_) do
    quote do
      alias Sake.Auth.{Client, Code, Consent, TokenRecord, Tokens}

      defp store(config), do: {elem(config.store, 0), config.store_state}

      unquote(record_cases())
      unquote(consent_and_prune_cases())
    end
  end

  defp record_cases do
    quote do
      test "clients", %{config: config} do
        {mod, state} = store(config)

        client = %Client{
          id: "dc_1",
          name: "A",
          kind: :dynamic,
          redirect_uris: ["http://127.0.0.1:1/cb"],
          grant_types: ["authorization_code"],
          token_endpoint_auth_method: "none"
        }

        assert :ok = mod.put_client(state, client)
        assert {:ok, ^client} = mod.get_client(state, "dc_1")
        assert [^client] = mod.list_clients(state)
        assert :ok = mod.delete_client(state, "dc_1")
        assert :error = mod.get_client(state, "dc_1")
      end

      test "codes are consumed once", %{config: config} do
        {mod, state} = store(config)

        code = %Code{
          hash: Tokens.hash("c1"),
          client_id: "c",
          redirect_uri: "http://127.0.0.1:1/cb",
          code_challenge: "x",
          scopes: [],
          resource: "r",
          subject_id: "u",
          expires_at: DateTime.utc_now() |> DateTime.add(600) |> DateTime.truncate(:second)
        }

        assert :ok = mod.put_code(state, code)
        assert {:ok, ^code} = mod.consume_code(state, code.hash)
        assert :error = mod.consume_code(state, code.hash)
      end

      test "tokens, families and revocation", %{config: config} do
        {mod, state} = store(config)
        {_a, _r, %{access: a, refresh: r}} = issue(config, %{family_id: "f1", subject_id: "u1"})
        {_a2, _r2, %{access: a2}} = issue(config, %{family_id: "f2", subject_id: "u1"})
        assert {:ok, _} = mod.consume_refresh(state, r.hash)
        assert {:ok, %TokenRecord{used_at: %DateTime{}}} = mod.get_token(state, :refresh, r.hash)
        assert :ok = mod.revoke_family(state, "f1")

        assert {:ok, %TokenRecord{revoked_at: %DateTime{}}} =
                 mod.get_token(state, :access, a.hash)

        assert {:ok, %TokenRecord{revoked_at: nil}} = mod.get_token(state, :access, a2.hash)
        assert :ok = mod.revoke_token(state, a2.id)

        assert {:ok, %TokenRecord{revoked_at: %DateTime{}}} =
                 mod.get_token(state, :access, a2.hash)

        assert length(mod.tokens_for_subject(state, "u1")) == 4
      end

      test "consume_refresh marks a refresh token used at most once", %{config: config} do
        {mod, state} = store(config)
        {_a, _r, %{refresh: r}} = issue(config, %{family_id: "f1", subject_id: "u1"})

        assert {:ok, %TokenRecord{used_at: nil}} = mod.consume_refresh(state, r.hash)

        assert {:error, :used, %TokenRecord{used_at: %DateTime{}}} =
                 mod.consume_refresh(state, r.hash)

        assert :error = mod.consume_refresh(state, "unknown")
      end
    end
  end

  defp consent_and_prune_cases do
    quote do
      test "consents", %{config: config} do
        {mod, state} = store(config)

        consent = %Consent{
          subject_id: "u1",
          client_id: "c",
          resource: "https://x/acme/mcp",
          scopes: ["a"],
          inserted_at: DateTime.utc_now()
        }

        beta = %{consent | resource: "https://x/beta/mcp", scopes: ["b"]}

        assert :ok = mod.put_consent(state, consent)
        assert :ok = mod.put_consent(state, beta)

        assert {:ok, %Consent{scopes: ["a"], resource: "https://x/acme/mcp"}} =
                 mod.get_consent(state, "u1", "c", "https://x/acme/mcp")

        assert {:ok, %Consent{scopes: ["b"]}} =
                 mod.get_consent(state, "u1", "c", "https://x/beta/mcp")

        assert :error = mod.get_consent(state, "u1", "c", "https://x/gamma/mcp")
        assert :ok = mod.put_consent(state, %{consent | scopes: ["a", "b"]})

        assert {:ok, %Consent{scopes: ["a", "b"]}} =
                 mod.get_consent(state, "u1", "c", "https://x/acme/mcp")

        assert :ok = mod.delete_consent(state, "u1", "c", "https://x/acme/mcp")
        assert :error = mod.get_consent(state, "u1", "c", "https://x/acme/mcp")
        assert {:ok, _} = mod.get_consent(state, "u1", "c", "https://x/beta/mcp")

        assert :ok = mod.put_consent(state, consent)
        assert :ok = mod.put_consent(state, %{consent | client_id: "other"})
        assert :ok = mod.delete_consent(state, "u1", "c", :all)
        assert :error = mod.get_consent(state, "u1", "c", "https://x/acme/mcp")
        assert :error = mod.get_consent(state, "u1", "c", "https://x/beta/mcp")
        assert {:ok, _} = mod.get_consent(state, "u1", "other", "https://x/acme/mcp")
      end

      test "prune forgets old consents that no live token family uses", %{config: config} do
        {mod, state} = store(config)
        now = DateTime.utc_now()
        old = DateTime.add(now, -100)
        resource = "http://www.example.com/mcp"

        consent = fn client_id, at ->
          %Consent{
            subject_id: "u7",
            client_id: client_id,
            resource: resource,
            scopes: [],
            inserted_at: at
          }
        end

        # old, and its family is alive: kept
        mod.put_consent(state, consent.("live", old))
        issue(config, %{client_id: "live", subject_id: "u7", family_id: "fl"})
        # old, and its family was revoked: forgotten
        mod.put_consent(state, consent.("revoked", old))
        issue(config, %{client_id: "revoked", subject_id: "u7", family_id: "fr"})
        mod.revoke_family(state, "fr")
        # old, never used for a token: forgotten
        mod.put_consent(state, consent.("unused", old))
        # recent, no tokens: kept
        mod.put_consent(state, consent.("recent", now))

        assert :ok = mod.prune(state, now, DateTime.add(now, -10))
        assert {:ok, _} = mod.get_consent(state, "u7", "live", resource)
        assert :error = mod.get_consent(state, "u7", "revoked", resource)
        assert :error = mod.get_consent(state, "u7", "unused", resource)
        assert {:ok, _} = mod.get_consent(state, "u7", "recent", resource)
      end

      test "prune removes expired codes and tokens", %{config: config} do
        {mod, state} = store(config)
        past = DateTime.add(DateTime.utc_now(), -10)

        mod.put_code(state, %Code{
          hash: "old",
          client_id: "c",
          redirect_uri: "http://127.0.0.1:1/cb",
          code_challenge: "x",
          scopes: [],
          resource: "r",
          subject_id: "u9",
          expires_at: past
        })

        mod.put_token(state, %TokenRecord{
          id: "t-old",
          kind: :access,
          hash: "h-old",
          family_id: "f",
          client_id: "c",
          subject_id: "u9",
          scopes: [],
          resource: "r",
          expires_at: past,
          inserted_at: past
        })

        {_, _, %{access: live}} = issue(config, %{subject_id: "u9"})
        assert :ok = mod.prune(state, DateTime.utc_now(), DateTime.add(DateTime.utc_now(), -60))
        assert :error = mod.consume_code(state, "old")
        assert :error = mod.get_token(state, :access, "h-old")
        assert {:ok, _} = mod.get_token(state, :access, live.hash)
      end
    end
  end
end
