defmodule Sake.Auth.RotationRaceTest.LiveRepo do
  @moduledoc false
  # The test database without the sandbox: every process its own
  # connection, so row locks really make one transaction wait for another.
  use Ecto.Repo, otp_app: :sake, adapter: Ecto.Adapters.Postgres
end

defmodule Sake.Auth.RotationRaceTest do
  # A family revocation racing a refresh rotation on PostgreSQL (issue
  # #54): the revocation locks the family's rows before revoking them, so
  # it waits for a rotation in progress and then revokes its new pair too.
  use ExUnit.Case, async: false
  import Ecto.Query

  alias Sake.Auth.RotationRaceTest.LiveRepo
  alias Sake.Auth.Store.Ecto, as: Store
  alias Sake.Auth.TokenRecord

  @family "rotation-race-family"

  setup do
    url = System.get_env("DATABASE_URL", "ecto://postgres@localhost/sake_test")
    start_supervised!({LiveRepo, url: url, pool_size: 3, log: false})
    on_exit(fn -> cleanup(url) end)
    %{state: Store.init(repo: LiveRepo)}
  end

  # The rows are committed for real: delete them through a connection of
  # their own, once the test's repo is gone.
  defp cleanup(url) do
    {:ok, pid} = LiveRepo.start_link(url: url, pool_size: 1, log: false, name: nil)
    LiveRepo.put_dynamic_repo(pid)
    LiveRepo.delete_all(from(t in "sake_oauth_tokens", where: t.family_id == ^@family))
    Supervisor.stop(pid)
  end

  defp token(id, kind) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %TokenRecord{
      id: id,
      kind: kind,
      hash: "hash-" <> id,
      family_id: @family,
      client_id: "c",
      subject_id: "u",
      scopes: [],
      resource: "r",
      expires_at: DateTime.add(now, 3_600),
      inserted_at: now
    }
  end

  defp revoked?(state, kind, hash) do
    {:ok, %{revoked_at: at}} = Store.get_token(state, kind, hash)
    at != nil
  end

  test "a revocation waits for a rotation in progress, then revokes its new pair", %{
    state: state
  } do
    :ok = Store.put_token(state, token("consumed", :refresh))
    test = self()

    # A rotation in progress: the consumed token's row locked, as
    # `put_rotated_tokens/3` locks it, and the new token not inserted yet.
    rotation =
      Task.async(fn ->
        LiveRepo.transaction(fn ->
          LiveRepo.one!(
            from(t in "sake_oauth_tokens",
              where: t.hash == "hash-consumed",
              lock: "FOR UPDATE",
              select: t.id
            )
          )

          send(test, :locked)
          receive do: (:go -> :ok)
          :ok = Store.put_token(state, token("new", :access))
        end)
      end)

    assert_receive :locked
    revocation = Task.async(fn -> Store.revoke_family(state, @family) end)
    refute Task.yield(revocation, 300)

    send(rotation.pid, :go)
    assert {:ok, :ok} = Task.await(rotation)
    assert :ok = Task.await(revocation)

    assert revoked?(state, :refresh, "hash-consumed")
    assert revoked?(state, :access, "hash-new")
  end

  test "a rotation after a revocation stores nothing", %{state: state} do
    :ok = Store.put_token(state, token("consumed", :refresh))
    :ok = Store.revoke_family(state, @family)

    assert :revoked = Store.put_rotated_tokens(state, "hash-consumed", [token("new", :access)])
    assert :error = Store.get_token(state, :access, "hash-new")
  end
end
