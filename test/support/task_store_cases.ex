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
        assert :ok = mod.insert(state, r)
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
        :ok = mod.insert(state, record("t2"))

        add = fn i -> fn r -> %{r | answers: Map.put(r.answers, "k#{i}", i)} end end

        1..20
        |> Enum.map(fn i -> Task.async(fn -> mod.update(state, "t2", add.(i)) end) end)
        |> Task.await_many()

        assert {:ok, %{answers: answers}} = mod.get(state, "t2")
        assert map_size(answers) == 20
      end

      test "prune deletes the expired tasks only", %{store: {mod, state}} do
        past = DateTime.add(Sake.Tasks.now(), -1, :second)
        :ok = mod.insert(state, record("old", expires_at: past))
        :ok = mod.insert(state, record("new"))
        assert :ok = mod.prune(state, Sake.Tasks.now())
        assert mod.get(state, "old") == :error
        assert {:ok, _} = mod.get(state, "new")
      end
    end
  end
end
