defmodule SakeTest.StoreCases do
  @moduledoc "The `Sake.Auth.Store` behaviour tests, run against every store."

  defmacro __using__(_) do
    quote do
      alias Sake.Auth.{Client, Code, Consent, DeviceGrant, PushedRequest, TokenRecord, Tokens}

      defp store(config), do: {elem(config.store, 0), config.store_state}

      unquote(record_cases())
      unquote(code_replay_cases())
      unquote(consent_and_prune_cases())
      unquote(once_cases())
      unquote(client_prune_cases())
      unquote(device_cases())
      unquote(device_token_cases())
      unquote(pushed_request_cases())
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
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
          redirect_uris: ["http://127.0.0.1:1/cb"],
          grant_types: ["authorization_code"],
          token_endpoint_auth_method: "none",
          require_pushed_authorization_requests: true
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
          dpop_jkt: "0ZcOCORZNYy-DWpqq30jZyJGHTN0d2HglBV3uiguA4I",
          acr: "mfa",
          auth_time: DateTime.utc_now() |> DateTime.add(-30) |> DateTime.truncate(:second),
          expires_at: DateTime.utc_now() |> DateTime.add(600) |> DateTime.truncate(:second)
        }

        assert :ok = mod.put_code(state, code)
        assert {:ok, ^code} = mod.consume_code(state, code.hash)
        assert :error = mod.consume_code(state, code.hash)
      end

      test "tokens keep how their person signed in", %{config: config} do
        {mod, state} = store(config)
        at = DateTime.utc_now() |> DateTime.add(-90) |> DateTime.truncate(:second)

        {_a, _r, %{access: a, refresh: r}} =
          issue(config, %{family_id: "f-acr", acr: "mfa", auth_time: at})

        assert {:ok, %TokenRecord{acr: "mfa", auth_time: ^at}} =
                 mod.get_token(state, :access, a.hash)

        assert {:ok, %TokenRecord{acr: "mfa", auth_time: ^at}} =
                 mod.consume_refresh(state, r.hash)

        {_a, _r, %{access: plain}} = issue(config, %{family_id: "f-plain"})

        assert {:ok, %TokenRecord{acr: nil, auth_time: nil}} =
                 mod.get_token(state, :access, plain.hash)
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
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
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

  defp client_prune_cases do
    quote do
      test "prune forgets dynamic clients that nothing came to use", %{config: config} do
        {mod, state} = store(config)
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        old = DateTime.add(now, -2 * 86_400)

        client = fn id, kind, at ->
          :ok =
            mod.put_client(state, %Client{
              id: id,
              name: id,
              kind: kind,
              redirect_uris: ["http://127.0.0.1:1/cb"],
              inserted_at: at
            })
        end

        for id <- ~w(unused revoked live consented coded) do
          client.("dc_" <> id, :dynamic, old)
        end

        client.("dc_recent", :dynamic, now)
        client.("rc_unused", :registered, old)

        {_, _, %{access: a, refresh: r}} =
          issue(config, %{client_id: "dc_revoked", family_id: "f-revoked"})

        :ok = mod.revoke_family(state, "f-revoked")
        issue(config, %{client_id: "dc_live", family_id: "f-live"})

        :ok =
          mod.put_consent(state, %Consent{
            subject_id: "u1",
            client_id: "dc_consented",
            resource: "r",
            scopes: [],
            inserted_at: now
          })

        :ok =
          mod.put_code(state, %Code{
            hash: "code-pending",
            client_id: "dc_coded",
            redirect_uri: "http://127.0.0.1:1/cb",
            code_challenge: "x",
            scopes: [],
            resource: "r",
            subject_id: "u1",
            expires_at: DateTime.add(now, 60)
          })

        assert :ok =
                 mod.prune(state, now, %{
                   consents: DateTime.add(now, -30 * 86_400),
                   unused_clients: DateTime.add(now, -86_400)
                 })

        assert :error = mod.get_client(state, "dc_unused")
        assert :error = mod.get_client(state, "dc_revoked")

        for id <- ~w(dc_live dc_consented dc_coded dc_recent rc_unused),
            do: assert({:ok, _} = mod.get_client(state, id), id)

        # The revoked client's tokens were its own business, and are left.
        assert {:ok, _} = mod.get_token(state, :access, a.hash)
        assert {:ok, _} = mod.get_token(state, :refresh, r.hash)
      end

      test "Sake.Auth.prune/1 prunes after unused_client_ttl", %{config: config} do
        {mod, state} = store(config)
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        for {id, age} <- [{"dc_hour", 3_600}, {"dc_week", 7 * 86_400}] do
          :ok =
            mod.put_client(state, %Client{
              id: id,
              name: id,
              kind: :dynamic,
              redirect_uris: ["http://127.0.0.1:1/cb"],
              inserted_at: DateTime.add(now, -age)
            })
        end

        assert :ok = Sake.Auth.prune(config)
        assert {:ok, _} = mod.get_client(state, "dc_hour")
        assert :error = mod.get_client(state, "dc_week")

        assert :ok = Sake.Auth.prune(%{config | unused_client_ttl: 60})
        assert :error = mod.get_client(state, "dc_hour")
      end
    end
  end

  defp once_cases do
    quote do
      test "once records a key until it expires", %{config: config} do
        {mod, state} = store(config)
        now = System.system_time(:second)

        assert :ok = mod.once(state, "k1", now + 60)
        assert :replayed = mod.once(state, "k1", now + 60)
        assert :ok = mod.once(state, "k2", now + 60)

        assert :ok = mod.once(state, "old", now - 10)
        assert :ok = mod.prune_once(state, now)
        assert :replayed = mod.once(state, "k1", now + 60)
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

        assert :ok =
                 mod.prune(state, now, %{consents: DateTime.add(now, -10), unused_clients: now})

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

        # A consumed code's row, kept as the fence for its tokens, goes too.
        mod.put_code(state, %Code{
          hash: "used",
          client_id: "c",
          redirect_uri: "http://127.0.0.1:1/cb",
          code_challenge: "x",
          scopes: [],
          resource: "r",
          subject_id: "u9",
          expires_at: past
        })

        assert {:ok, _} = mod.consume_code(state, "used")

        now = DateTime.utc_now()

        assert :ok =
                 mod.prune(state, now, %{consents: DateTime.add(now, -60), unused_clients: now})

        assert :error = mod.consume_code(state, "old")
        assert :revoked = mod.put_code_tokens(state, "used", [])
        assert :error = mod.get_token(state, :access, "h-old")
        assert {:ok, _} = mod.get_token(state, :access, live.hash)
      end
    end
  end

  defp device_cases do
    quote do
      @signed_in %{acr: "pwd", auth_time: nil}

      defp device_grant(mod, state, name, attrs \\ %{}) do
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        grant =
          struct!(
            %DeviceGrant{
              hash: Tokens.hash("device-" <> name),
              user_code_hash: Tokens.hash("user-" <> name),
              client_id: "c",
              scopes: ["a", "b"],
              resource: "r",
              interval: 5,
              expires_at: DateTime.add(now, 600),
              inserted_at: now
            },
            attrs
          )

        :ok = mod.put_device_grant(state, grant)
        grant
      end

      test "device grants: found by user code, decided once", %{config: config} do
        {mod, state} = store(config)
        grant = device_grant(mod, state, "found")

        assert {:ok, %DeviceGrant{status: :pending, scopes: ["a", "b"], subject_id: nil} = found} =
                 mod.get_device_grant_by_user_code(state, grant.user_code_hash)

        assert found.hash == grant.hash
        assert :error = mod.get_device_grant_by_user_code(state, Tokens.hash("user-unknown"))

        at = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.truncate(:second)

        assert :ok =
                 mod.decide_device_grant(
                   state,
                   grant.hash,
                   {:approved, "u1", ["a"], %{acr: "mfa", auth_time: at}}
                 )

        assert :error = mod.decide_device_grant(state, grant.hash, :denied)
        assert :error = mod.decide_device_grant(state, Tokens.hash("unknown"), :denied)

        assert {:ok,
                %DeviceGrant{
                  status: :approved,
                  subject_id: "u1",
                  scopes: ["a"],
                  acr: "mfa",
                  auth_time: ^at
                }} = mod.get_device_grant_by_user_code(state, grant.user_code_hash)
      end

      test "device grants keep their request's extra", %{config: config} do
        {mod, state} = store(config)
        extra = %{"acr_values" => ["mfa", "hwk"], "max_age" => 300}
        grant = device_grant(mod, state, "extra", %{extra: extra})

        assert {:ok, %DeviceGrant{extra: ^extra, acr: nil, auth_time: nil}} =
                 mod.get_device_grant_by_user_code(state, grant.user_code_hash)
      end

      test "device grants: each poll is answered and recorded atomically", %{config: config} do
        {mod, state} = store(config)
        grant = device_grant(mod, state, "polled")
        t0 = DateTime.utc_now()
        at = fn ms -> DateTime.add(t0, ms, :millisecond) end

        assert :pending = mod.poll_device_grant(state, grant.hash, "c", at.(0))
        # Sooner than the interval after the last poll, the slow_down
        # itself counting as one.
        assert :slow_down = mod.poll_device_grant(state, grant.hash, "c", at.(4_000))
        assert :slow_down = mod.poll_device_grant(state, grant.hash, "c", at.(8_500))
        assert :pending = mod.poll_device_grant(state, grant.hash, "c", at.(13_500))

        # Another client, or a code nobody issued, learns nothing.
        assert :error = mod.poll_device_grant(state, grant.hash, "other", at.(30_000))
        assert :error = mod.poll_device_grant(state, Tokens.hash("x"), "c", at.(30_000))

        :ok = mod.decide_device_grant(state, grant.hash, {:approved, "u1", ["a"], @signed_in})
        assert :slow_down = mod.poll_device_grant(state, grant.hash, "c", at.(14_000))

        assert {:approved,
                %DeviceGrant{subject_id: "u1", scopes: ["a"], resource: "r", acr: "pwd"}} =
                 mod.poll_device_grant(state, grant.hash, "c", at.(20_000))

        # Issued once: every later poll says it was used.
        assert :used = mod.poll_device_grant(state, grant.hash, "c", at.(40_000))
        assert :used = mod.poll_device_grant(state, grant.hash, "c", at.(60_000))
      end

      test "device grants: denied and expired", %{config: config} do
        {mod, state} = store(config)
        denied = device_grant(mod, state, "denied")
        :ok = mod.decide_device_grant(state, denied.hash, :denied)
        assert :denied = mod.poll_device_grant(state, denied.hash, "c", DateTime.utc_now())

        past = DateTime.utc_now() |> DateTime.add(-1) |> DateTime.truncate(:second)
        expired = device_grant(mod, state, "expired", %{expires_at: past})
        assert :expired = mod.poll_device_grant(state, expired.hash, "c", DateTime.utc_now())
      end
    end
  end

  defp device_token_cases do
    quote do
      test "a device grant's tokens are stored only while no replay revoked its family", %{
        config: config
      } do
        {mod, state} = store(config)

        issued = fn name ->
          grant = device_grant(mod, state, name)

          :ok =
            mod.decide_device_grant(
              state,
              grant.hash,
              {:approved, "u-device", [], %{acr: nil, auth_time: nil}}
            )

          {:approved, _} = mod.poll_device_grant(state, grant.hash, "c", DateTime.utc_now())
          grant.hash
        end

        pair = fn hash ->
          {_, _, %{access: a, refresh: r}} =
            Tokens.new_pair(config, %{
              family_id: hash,
              client_id: "c",
              subject_id: "u-device",
              scopes: [],
              resource: "r"
            })

          [a, r]
        end

        # Not issued yet: no tokens.
        pending = device_grant(mod, state, "not-issued")
        assert :revoked = mod.put_device_tokens(state, pending.hash, pair.(pending.hash))

        # The replay revoked the family first: nothing is stored.
        replayed = issued.("replayed")
        assert :ok = mod.revoke_family(state, replayed)
        [a, r] = pair.(replayed)
        assert :revoked = mod.put_device_tokens(state, replayed, [a, r])
        assert :error = mod.get_token(state, :access, a.hash)

        # The pair was stored first: the replay revokes it.
        redeemed = issued.("redeemed")
        [a, r] = pair.(redeemed)
        assert :ok = mod.put_device_tokens(state, redeemed, [a, r])
        assert {:ok, %TokenRecord{revoked_at: nil}} = mod.get_token(state, :access, a.hash)
        assert :ok = mod.revoke_family(state, redeemed)

        assert {:ok, %TokenRecord{revoked_at: %DateTime{}}} =
                 mod.get_token(state, :refresh, r.hash)
      end

      test "prune removes expired device grants, and a pending one keeps its client", %{
        config: config
      } do
        {mod, state} = store(config)
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        old = DateTime.add(now, -2 * 86_400)

        for id <- ~w(dc_device dc_device_gone) do
          :ok =
            mod.put_client(state, %Client{
              id: id,
              name: id,
              kind: :dynamic,
              grant_types: ["urn:ietf:params:oauth:grant-type:device_code"],
              inserted_at: old
            })
        end

        live = device_grant(mod, state, "live", %{client_id: "dc_device"})

        gone =
          device_grant(mod, state, "gone", %{
            client_id: "dc_device_gone",
            expires_at: DateTime.add(now, -10)
          })

        assert :ok =
                 mod.prune(state, now, %{
                   consents: DateTime.add(now, -30 * 86_400),
                   unused_clients: DateTime.add(now, -86_400)
                 })

        assert {:ok, _} = mod.get_device_grant_by_user_code(state, live.user_code_hash)
        assert :error = mod.get_device_grant_by_user_code(state, gone.user_code_hash)
        assert {:ok, _} = mod.get_client(state, "dc_device")
        assert :error = mod.get_client(state, "dc_device_gone")
      end
    end
  end

  defp pushed_request_cases do
    quote do
      defp pushed_request(mod, state, name, attrs \\ %{}) do
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        request =
          struct!(
            %PushedRequest{
              hash: Tokens.hash("urn:ietf:params:oauth:request_uri:" <> name),
              client_id: "c",
              redirect_uri: "http://127.0.0.1:1/cb",
              state: "xyz",
              code_challenge: "x",
              scopes: ["a", "b"],
              resource: "r",
              extra: %{"dpop_jkt" => "0ZcOCORZNYy-DWpqq30jZyJGHTN0d2HglBV3uiguA4I"},
              expires_at: DateTime.add(now, 60),
              inserted_at: now
            },
            attrs
          )

        :ok = mod.put_pushed_request(state, request)
        request
      end

      test "pushed requests are consumed once", %{config: config} do
        {mod, state} = store(config)
        request = pushed_request(mod, state, "once")
        assert {:ok, ^request} = mod.consume_pushed_request(state, request.hash)
        assert :error = mod.consume_pushed_request(state, request.hash)
        assert :error = mod.consume_pushed_request(state, Tokens.hash("unknown"))

        # Without a state or anything in extra.
        bare = pushed_request(mod, state, "bare", %{state: nil, extra: %{}})
        assert {:ok, ^bare} = mod.consume_pushed_request(state, bare.hash)
      end

      test "of concurrent consumes of a pushed request, one gets it", %{config: config} do
        {mod, state} = store(config)
        request = pushed_request(mod, state, "raced")

        results =
          1..8
          |> Enum.map(fn _ ->
            Task.async(fn -> mod.consume_pushed_request(state, request.hash) end)
          end)
          |> Enum.map(&Task.await/1)

        assert [{:ok, _}] = Enum.filter(results, &match?({:ok, _}, &1))
        assert Enum.count(results, &(&1 == :error)) == 7
      end

      test "prune removes expired pushed requests, and a live one keeps its client", %{
        config: config
      } do
        {mod, state} = store(config)
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        old = DateTime.add(now, -2 * 86_400)

        for id <- ~w(dc_pushed dc_pushed_gone) do
          :ok =
            mod.put_client(state, %Client{
              id: id,
              name: id,
              kind: :dynamic,
              redirect_uris: ["http://127.0.0.1:1/cb"],
              inserted_at: old
            })
        end

        live = pushed_request(mod, state, "live", %{client_id: "dc_pushed"})

        gone =
          pushed_request(mod, state, "gone", %{
            client_id: "dc_pushed_gone",
            expires_at: DateTime.add(now, -10)
          })

        assert :ok =
                 mod.prune(state, now, %{
                   consents: DateTime.add(now, -30 * 86_400),
                   unused_clients: DateTime.add(now, -86_400)
                 })

        assert {:ok, _} = mod.get_client(state, "dc_pushed")
        assert :error = mod.get_client(state, "dc_pushed_gone")
        assert :error = mod.consume_pushed_request(state, gone.hash)
        assert {:ok, _} = mod.consume_pushed_request(state, live.hash)
      end
    end
  end
end
