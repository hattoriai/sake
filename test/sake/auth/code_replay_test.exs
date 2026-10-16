defmodule Sake.Auth.CodeReplayTest.PauseStore do
  @moduledoc false
  # Delegates to another store (`inner:`), except that a request whose
  # process asked for it (`pause/0`) stops right after consuming its code,
  # until the test resumes it: a replay of the code can then run in between,
  # deterministically.
  @behaviour Sake.Auth.Store

  def pause, do: Process.put(__MODULE__, self())

  def child_spec(opts) do
    {module, inner_opts} = opts[:inner]

    if Code.ensure_loaded?(module) and function_exported?(module, :child_spec, 1),
      do: module.child_spec(inner_opts),
      else: %{id: __MODULE__, start: {Agent, :start_link, [fn -> nil end]}}
  end

  def init(opts) do
    {module, inner_opts} = opts[:inner]
    {module, module.init(inner_opts)}
  end

  def consume_code({m, s}, hash) do
    result = m.consume_code(s, hash)

    if test = Process.get({__MODULE__, :test}) do
      send(test, {:consumed, self()})
      receive do: (:resume -> :ok)
    end

    result
  end

  def put_client({m, s}, c), do: m.put_client(s, c)
  def get_client({m, s}, id), do: m.get_client(s, id)
  def list_clients({m, s}), do: m.list_clients(s)
  def delete_client({m, s}, id), do: m.delete_client(s, id)
  def put_code({m, s}, c), do: m.put_code(s, c)
  def put_code_tokens({m, s}, hash, tokens), do: m.put_code_tokens(s, hash, tokens)
  def put_token({m, s}, token), do: m.put_token(s, token)
  def get_token({m, s}, kind, hash), do: m.get_token(s, kind, hash)
  def consume_refresh({m, s}, hash), do: m.consume_refresh(s, hash)
  def revoke_token({m, s}, id), do: m.revoke_token(s, id)
  def revoke_family({m, s}, family_id), do: m.revoke_family(s, family_id)
  def tokens_for_subject({m, s}, subject_id), do: m.tokens_for_subject(s, subject_id)
  def once({m, s}, key, expires_at), do: m.once(s, key, expires_at)
  def prune_once({m, s}, now), do: m.prune_once(s, now)
  def put_consent({m, s}, c), do: m.put_consent(s, c)

  def get_consent({m, s}, sub, client_id, resource),
    do: m.get_consent(s, sub, client_id, resource)

  def delete_consent({m, s}, sub, client_id, resource),
    do: m.delete_consent(s, sub, client_id, resource)

  def prune({m, s}, now, consents_before), do: m.prune(s, now, consents_before)
end

defmodule Sake.Auth.CodeReplayTest do
  # A replay of an authorization code revokes every token issued for it,
  # even when it races the request that consumed the code (issue #37).
  use SakeTest.AuthCase, async: false
  import Plug.Test
  import Plug.Conn

  alias Sake.Auth.{Authorize, Tokens}
  alias Sake.Auth.CodeReplayTest.PauseStore

  @verifier "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
  @challenge "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

  defp redeem(client, code, verifier \\ @verifier) do
    params = %{
      "grant_type" => "authorization_code",
      "code" => code,
      "client_id" => client.id,
      "redirect_uri" => hd(client.redirect_uris),
      "code_verifier" => verifier
    }

    conn(:post, "/oauth/token", URI.encode_query(params))
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> Sake.Auth.Token.call(Sake.Auth.Token.init([]))
  end

  defp code(config, client) do
    Authorize.issue_code(
      config,
      %{
        client_id: client.id,
        redirect_uri: hd(client.redirect_uris),
        code_challenge: @challenge,
        scopes: ["issues:read"],
        resource: "http://www.example.com/mcp"
      },
      "u1"
    )
  end

  defp live_tokens(config, code) do
    {mod, state} = Sake.Auth.store(config)
    family = Tokens.hash(code)
    now = DateTime.utc_now()

    for t <- mod.tokens_for_subject(state, "u1"),
        t.family_id == family,
        Tokens.valid?(t, now),
        do: t
  end

  defp body(conn), do: JSON.decode!(conn.resp_body)

  for {store, tags} <- [
        ets: [auth: [store: {PauseStore, inner: {Sake.Auth.Store.ETS, []}}]],
        ecto: [
          store: :ecto,
          auth: [store: {PauseStore, inner: {Sake.Auth.Store.Ecto, repo: SakeTest.Repo}}]
        ]
      ] do
    describe "#{store}" do
      @describetag tags

      test "a replay between consuming the code and storing its pair: no live token", %{
        config: config
      } do
        client = public_client(config)
        code = code(config, client)
        test = self()

        first =
          Task.async(fn ->
            Process.put({PauseStore, :test}, test)
            redeem(client, code)
          end)

        assert_receive {:consumed, pid}, 5_000

        replay = redeem(client, code)
        assert replay.status == 400 and body(replay)["error"] == "invalid_grant"

        send(pid, :resume)
        first = Task.await(first)

        assert first.status == 400 and body(first)["error"] == "invalid_grant"
        assert live_tokens(config, code) == []
      end

      test "a replay after the pair was stored revokes it", %{config: config} do
        client = public_client(config)
        code = code(config, client)

        first = redeem(client, code)
        assert first.status == 200
        assert [_, _] = live_tokens(config, code)

        assert redeem(client, code).status == 400
        assert live_tokens(config, code) == []
      end

      test "a code is single use and needs its verifier", %{config: config} do
        client = public_client(config)
        code = code(config, client)

        wrong = redeem(client, code, String.duplicate("a", 43))
        assert wrong.status == 400 and body(wrong)["error_description"] =~ "code_verifier"
        assert redeem(client, code).status == 400
        assert live_tokens(config, code) == []
      end
    end
  end
end
