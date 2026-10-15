defmodule Sake.Tasks.StoreETSTest do
  use ExUnit.Case, async: false

  setup do
    %{store: Sake.Tasks.config().store}
  end

  use SakeTest.TaskStoreCases
end

defmodule Sake.Tasks.StoreEctoTest do
  use ExUnit.Case, async: false
  alias Ecto.Adapters.SQL.Sandbox
  alias SakeTest.ModernClient

  setup do
    :ok = Sandbox.checkout(SakeTest.Repo)
    Sandbox.mode(SakeTest.Repo, {:shared, self()})
    module = Sake.Tasks.Store.Ecto
    %{store: {module, module.init(repo: SakeTest.Repo)}}
  end

  use SakeTest.TaskStoreCases

  test "the migration is reversible" do
    opts = [all: true, log: false, migration_lock: false]
    Ecto.Migrator.run(SakeTest.Repo, [{1, SakeTest.TasksMigration}], :down, opts)
    Ecto.Migrator.run(SakeTest.Repo, [{1, SakeTest.TasksMigration}], :up, opts)
  end

  test "a task runs, waits for input and completes through the database", %{store: store} do
    config = Sake.Tasks.config()
    :persistent_term.put({Sake.Tasks, :config}, %{config | store: store})
    on_exit(fn -> :persistent_term.put({Sake.Tasks, :config}, config) end)

    opts = ModernClient.opts(server: SakeDev.ConformanceServer)
    caps = %{"elicitation" => %{}, "extensions" => %{"io.modelcontextprotocol/tasks" => %{}}}
    post = &ModernClient.json(ModernClient.post(opts, &1, &2, capabilities: caps))

    assert %{"result" => %{"resultType" => "task", "taskId" => id}} =
             post.("tools/call", %{
               "name" => "confirm_delete",
               "arguments" => %{"filename" => "f"}
             })

    assert {:ok, %Sake.Tasks.Record{tool: "confirm_delete"}} =
             elem(store, 0).get(elem(store, 1), id)

    wait = fn wait, status ->
      case post.("tasks/get", %{"taskId" => id}) do
        %{"result" => %{"status" => ^status} = task} ->
          task

        _ ->
          Process.sleep(20)
          wait.(wait, status)
      end
    end

    assert %{"inputRequests" => %{"confirm" => _}} = wait.(wait, "input_required")

    post.("tasks/update", %{
      "taskId" => id,
      "inputResponses" => %{
        "confirm" => %{"action" => "accept", "content" => %{"confirm" => true}}
      }
    })

    assert %{"result" => %{"content" => [%{"text" => "Deleted f."}]}} = wait.(wait, "completed")
  end
end
