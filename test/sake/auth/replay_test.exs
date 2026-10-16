defmodule Sake.Auth.ReplayTest do
  # A single-use JWT recorded in a shared store is refused on every node,
  # not only the one that saw it (issue #35). A second node is this one
  # with its own table emptied: all it shares with the first is the store.
  use SakeTest.AuthCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Sake.Auth.{DPoP, Replay}
  alias Sake.Auth.Store.Ecto, as: EctoStore
  alias SakeTest.{Keys, ModernClient, Repo}

  @mcp "http://www.example.com/mcp"

  defp another_node, do: :ets.delete_all_objects(Replay)

  defp check(proof, opts \\ []),
    do: DPoP.verify(proof, Keyword.merge([htm: "POST", htu: [@mcp]], opts))

  describe "with the Ecto store" do
    @describetag store: :ecto

    test "a DPoP proof with the current nonce is good once, on any node" do
      {key, _jwk} = Keys.key()
      secret = String.duplicate("n", 64)
      nonce = DPoP.nonce(secret)
      proof = DPoP.proof(key, "POST", @mcp, access_token: "tok", nonce: nonce)

      assert {:ok, _jkt} = check(proof, access_token: "tok", nonce: secret)

      another_node()

      assert {:error, "invalid_dpop_proof", "The DPoP proof was already used"} =
               check(proof, access_token: "tok", nonce: secret)

      # A new proof from the same key is good.
      fresh = DPoP.proof(key, "POST", @mcp, access_token: "tok", nonce: nonce)
      assert {:ok, _} = check(fresh, access_token: "tok", nonce: secret)
    end

    test "client assertions and JWT grants are single use on any node" do
      exp = System.system_time(:second) + 60
      assert :ok = Replay.once("client-a", "jti-1", exp)
      another_node()
      assert {:error, :replayed} = Replay.once("client-a", "jti-1", exp)

      # Another issuer's same jti is another JWT.
      assert :ok = Replay.once("client-b", "jti-1", exp)
    end

    test "a jti of any length is recorded as a digest" do
      exp = System.system_time(:second) + 60
      jti = String.duplicate("x", 8_000)
      assert :ok = Replay.once("dpop:k", jti, exp)
      assert {:error, :replayed} = Replay.once("dpop:k", jti, exp)

      assert [%{key: key}] = Repo.all(EctoStore.Replay)
      assert byte_size(key) == 43
    end
  end

  describe "with the ETS store" do
    test "a proof is good once on this node" do
      {key, _jwk} = Keys.key()
      proof = DPoP.proof(key, "POST", @mcp)

      assert {:ok, _} = check(proof)
      assert {:error, "invalid_dpop_proof", _} = check(proof)
    end
  end

  describe "replay:" do
    setup do
      :ok = Sandbox.checkout(Repo)
      Sandbox.mode(Repo, {:shared, self()})
      stop_supervised!(Sake)
      :ok
    end

    test "names the shared store when there is no auth: store, as with external authorization" do
      start_supervised!(
        {Sake,
         replay: {EctoStore, repo: Repo},
         secret_key_base: ModernClient.secret(),
         streams: false,
         tasks: false}
      )

      exp = System.system_time(:second) + 60
      assert :ok = Replay.once("https://idp.example", "jti-1", exp)
      assert [_] = Repo.all(EctoStore.Replay)
      assert {:error, :replayed} = Replay.once("https://idp.example", "jti-1", exp)
    end
  end
end
