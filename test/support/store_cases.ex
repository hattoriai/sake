defmodule SakeTest.StoreCases do
  @moduledoc "The `Sake.Auth.Store` behaviour tests, run against every store."

  defmacro __using__(_) do
    quote do
      alias Sake.Auth.{Client, Code, Consent, TokenRecord, Tokens}

      defp store(config), do: {elem(config.store, 0), config.store_state}

      unquote(record_cases())
      unquote(code_replay_cases())
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

      test "a DPoP-bound token keeps its key's thumbprint", %{config: config} do
        {mod, state} = store(config)

        {_a, _r, %{access: a, refresh: r}} =
          issue(config, %{family_id: "fd", jkt: "thumb-a", refresh_jkt: "thumb-r"})

        assert {:ok, %TokenRecord{jkt: "thumb-a"}} = mod.get_token(state, :access, a.hash)
        assert {:ok, %TokenRecord{jkt: "thumb-r"}} = mod.consume_refresh(state, r.hash)

        {_a, _r, %{access: bearer}} = issue(config, %{family_id: "fb"})
        assert {:ok, %TokenRecord{jkt: nil}} = mod.get_token(state, :access, bearer.hash)
      end

      test "a machine client's keys, and its token without a subject", %{config: config} do
        {mod, state} = store(config)

        client = %Client{
          id: "rc_m",
          name: "Machine",
          kind: :registered,
          grant_types: ["client_credentials"],
          token_endpoint_auth_method: "private_key_jwt",
          jwks: %{"keys" => [%{"kty" => "EC", "crv" => "P-256", "x" => "x", "y" => "y"}]},
          jwks_uri: nil
        }

        assert :ok = mod.put_client(state, client)
        assert {:ok, ^client} = mod.get_client(state, "rc_m")

        assert :ok =
                 mod.put_client(state, %{client | jwks: nil, jwks_uri: "https://m.example/jwks"})

        assert {:ok, %Client{jwks: nil, jwks_uri: "https://m.example/jwks"}} =
                 mod.get_client(state, "rc_m")

        {access, record} =
          Tokens.issue_access(config, %{
            client_id: "rc_m",
            subject_id: nil,
            scopes: ["a"],
            resource: "https://x/mcp"
          })

        assert {:ok, %TokenRecord{subject_id: nil, client_id: "rc_m", kind: :access}} =
                 mod.get_token(state, :access, Tokens.hash(access))

        assert :ok = mod.revoke_token(state, record.id)

        assert {:ok, %TokenRecord{revoked_at: %DateTime{}}} =
                 mod.get_token(state, :access, record.hash)
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

  defp code_replay_cases do
    quote do
      test "a code's tokens are stored only while no replay revoked its family", %{
        config: config
      } do
        {mod, state} = store(config)
        expires = DateTime.utc_now() |> DateTime.add(600) |> DateTime.truncate(:second)

        code = fn name ->
          code = %Code{
            hash: Tokens.hash(name),
            client_id: "c",
            redirect_uri: "http://127.0.0.1:1/cb",
            code_challenge: "x",
            scopes: [],
            resource: "r",
            subject_id: "u-code",
            expires_at: expires
          }

          :ok = mod.put_code(state, code)
          {:ok, _} = mod.consume_code(state, code.hash)
          code.hash
        end

        pair = fn hash ->
          {_, _, %{access: a, refresh: r}} =
            Tokens.new_pair(config, %{
              family_id: hash,
              client_id: "c",
              subject_id: "u-code",
              scopes: [],
              resource: "r"
            })

          [a, r]
        end

        # The replay revoked the family first: nothing is stored.
        replayed = code.("replayed")
        assert :ok = mod.revoke_family(state, replayed)
        [a, r] = pair.(replayed)
        assert :revoked = mod.put_code_tokens(state, replayed, [a, r])
        assert :error = mod.get_token(state, :access, a.hash)
        assert :error = mod.get_token(state, :refresh, r.hash)

        # The pair was stored first: the replay revokes it.
        redeemed = code.("redeemed")
        [a, r] = pair.(redeemed)
        assert :ok = mod.put_code_tokens(state, redeemed, [a, r])
        assert {:ok, %TokenRecord{revoked_at: nil}} = mod.get_token(state, :access, a.hash)
        assert :ok = mod.revoke_family(state, redeemed)

        assert {:ok, %TokenRecord{revoked_at: %DateTime{}}} =
                 mod.get_token(state, :access, a.hash)

        assert {:ok, %TokenRecord{revoked_at: %DateTime{}}} =
                 mod.get_token(state, :refresh, r.hash)
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
