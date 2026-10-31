defmodule SakeTest.TaskStoreExecutionCases do
  @moduledoc """
  The `Sake.Tasks.Store` tests of recoverable execution (the job, the
  lease, `orphans/2`), run against every store.
  """

  defmacro __using__(_) do
    quote do
      alias Sake.Tasks.Record

      defp exec_record(id, attrs \\ []) do
        now = Sake.Tasks.now()

        struct!(
          %Record{
            id: id,
            principal: "subject:u1",
            tool: "t",
            ttl_ms: 60_000,
            poll_interval_ms: 1_000,
            created_at: now,
            updated_at: now,
            expires_at: DateTime.add(now, 60, :second)
          },
          attrs
        )
      end

      test "the execution fields round-trip, the job included", %{store: {mod, state}} do
        lease = DateTime.add(Sake.Tasks.now(), 30, :second)

        job = %Sake.Tasks.Job{
          task_id: "exec1",
          server: SakeDev.Server,
          tool: "echo",
          args: %{text: "hi"},
          context: %{scope: %{user: "u1"}, protocol_version: "2026-07-28"},
          attempt: 2,
          run_id: "run:abc"
        }

        r = exec_record("exec1", job: job, attempt: 2, lease_owner: "run:abc", lease_until: lease)
        :ok = mod.insert(state, r, :infinity)
        assert {:ok, ^r} = mod.get(state, "exec1")

        {:ok, _, handed} =
          mod.update(state, "exec1", &%{&1 | handle: "ext-1", lease_owner: nil, lease_until: nil})

        assert {:ok, ^handed} = mod.get(state, "exec1")
      end

      test "orphans: live tasks whose lease lapsed, not handed to an external job", %{
        store: {mod, state}
      } do
        now = Sake.Tasks.now()
        past = DateTime.add(now, -1, :second)
        future = DateTime.add(now, 30, :second)
        id = &"orph-#{&1}-#{System.unique_integer([:positive])}"

        lapsed = id.("lapsed")

        :ok =
          mod.insert(
            state,
            exec_record(lapsed, lease_owner: "run:a", lease_until: past),
            :infinity
          )

        :ok =
          mod.insert(
            state,
            exec_record(id.("held"), lease_owner: "run:b", lease_until: future),
            :infinity
          )

        :ok = mod.insert(state, exec_record(id.("free")), :infinity)

        :ok =
          mod.insert(
            state,
            exec_record(id.("external"), lease_until: past, handle: "ext"),
            :infinity
          )

        :ok =
          mod.insert(
            state,
            exec_record(id.("ended"), status: :completed, lease_until: past),
            :infinity
          )

        :ok =
          mod.insert(
            state,
            exec_record(id.("expired"), lease_until: past, expires_at: past),
            :infinity
          )

        assert lapsed in Enum.map(mod.orphans(state, now), & &1.id)

        assert Enum.filter(mod.orphans(state, now), &String.starts_with?(&1.id, "orph-"))
               |> Enum.map(& &1.id) ==
                 [lapsed]
      end
    end
  end
end
