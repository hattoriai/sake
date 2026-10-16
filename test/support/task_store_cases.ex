defmodule SakeTest.TaskStoreCases do
  @moduledoc "The `Sake.Tasks.Store` behaviour tests, run against every store."

  defmacro __using__(_) do
    quote do
      alias Sake.Tasks.Record

      defp record(id, attrs \\ []) do
        now = Sake.Tasks.now()

        struct!(
          %Record{
            id: id,
            principal: "subject:u1",
            tool: "t",
            scopes: ["admin"],
            ttl_ms: 60_000,
            poll_interval_ms: 1_000,
            created_at: now,
            updated_at: now,
            expires_at: DateTime.add(now, 60, :second)
          },
          attrs
        )
      end

      test "insert, get, update", %{store: {mod, state}} do
        r = record("t1")
        assert :ok = mod.insert(state, r, :infinity)
        assert {:ok, ^r} = mod.get(state, "t1")
        assert mod.get(state, "nope") == :error

        request = %{"method" => "elicitation/create", "params" => %{"message" => "?"}}

        assert {:ok, ^r, updated} =
                 mod.update(state, "t1", fn r ->
                   %{r | status: :input_required, input_requests: %{"k" => request}}
                 end)

        assert {:ok, ^updated} = mod.get(state, "t1")
        assert updated.status == :input_required and updated.input_requests == %{"k" => request}

        result = %{"content" => [%{"type" => "text", "text" => "ok"}], "isError" => false}

        {:ok, _, done} =
          mod.update(state, "t1", fn r ->
            %{
              r
              | status: :completed,
                input_requests: %{},
                answers: %{"k" => %{"action" => "accept"}},
                result: result,
                status_message: "done"
            }
          end)

        assert {:ok, ^done} = mod.get(state, "t1")
        assert done.result == result and done.answers == %{"k" => %{"action" => "accept"}}
        assert mod.update(state, "nope", & &1) == :error
      end

      test "concurrent updates of one task are never lost", %{store: {mod, state}} do
        :ok = mod.insert(state, record("t2"), :infinity)

        add = fn i -> fn r -> %{r | answers: Map.put(r.answers, "k#{i}", i)} end end

        1..20
        |> Enum.map(fn i -> Task.async(fn -> mod.update(state, "t2", add.(i)) end) end)
        |> Task.await_many()

        assert {:ok, %{answers: answers}} = mod.get(state, "t2")
        assert map_size(answers) == 20
      end

      test "insert refuses an owner's task beyond max live ones", %{store: {mod, state}} do
        past = DateTime.add(Sake.Tasks.now(), -1, :second)
        owner = "owner:" <> Integer.to_string(System.unique_integer([:positive]))
        other = owner <> "-other"
        mine = &record(&1, Keyword.put(&2, :principal, owner))

        # Ended and expired tasks take no slot.
        assert :ok = mod.insert(state, mine.("cap-done", status: :completed), 1)
        assert :ok = mod.insert(state, mine.("cap-old", expires_at: past), 1)
        assert :ok = mod.insert(state, mine.("cap1", []), 2)
        assert :ok = mod.insert(state, mine.("cap2", status: :input_required), 2)

        assert :full = mod.insert(state, mine.("cap3", []), 2)
        assert mod.get(state, "cap3") == :error
        assert :ok = mod.insert(state, record("cap-other", principal: other), 2)

        {:ok, _, _} = mod.update(state, "cap1", &%{&1 | status: :cancelled})
        assert :ok = mod.insert(state, mine.("cap3", []), 2)
        assert :full = mod.insert(state, mine.("cap4", []), 2)
        assert :ok = mod.insert(state, mine.("cap4", []), :infinity)
      end

      test "concurrent inserts for one owner never pass max", %{store: {mod, state}} do
        owner = "owner:" <> Integer.to_string(System.unique_integer([:positive]))

        results =
          1..10
          |> Enum.map(fn i ->
            Task.async(fn -> mod.insert(state, record("race#{i}", principal: owner), 3) end)
          end)
          |> Task.await_many()

        assert Enum.count(results, &(&1 == :ok)) == 3
      end

      test "prune deletes the expired tasks only", %{store: {mod, state}} do
        past = DateTime.add(Sake.Tasks.now(), -1, :second)
        :ok = mod.insert(state, record("old", expires_at: past), :infinity)
        :ok = mod.insert(state, record("new"), :infinity)
        assert :ok = mod.prune(state, Sake.Tasks.now())
        assert mod.get(state, "old") == :error
        assert {:ok, _} = mod.get(state, "new")
      end
    end
  end
end
