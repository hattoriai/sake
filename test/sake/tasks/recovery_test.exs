defmodule Sake.Tasks.RecoveryTest do
  # Recovery reads and changes Sake.Tasks's global configuration (its
  # runner) and reaps the shared store: the module runs alone.
  use ExUnit.Case, async: false

  import Sake.Test

  alias Sake.Tasks
  alias Sake.Tasks.{Job, Record}

  @caps %{"elicitation" => %{}, "extensions" => %{"io.modelcontextprotocol/tasks" => %{}}}

  # Each run tells the test it started. A run numbered below
  # `finish_from` blocks (the run the test kills, standing in for a node
  # that goes away); a later one completes.
  defmodule Flaky do
    use Sake.Tool, name: "flaky", description: "Dies on its first run", task: :required

    @impl true
    def execute(_args, ctx) do
      {n, finish_from} = Sake.Tasks.RecoveryTest.next_run(ctx)
      if n < finish_from, do: Process.sleep(:infinity), else: {:ok, "done on run #{n}"}
    end
  end

  defmodule Retried do
    use Sake.Tool,
      name: "retried",
      description: "Runs again when its run dies",
      task: :required,
      recovery: {:retry, 2}

    @impl true
    def execute(args, ctx), do: Flaky.execute(args, ctx)
  end

  # Asks, then (below `finish_from`) dies after the answer.
  defmodule Asker do
    use Sake.Tool,
      name: "asker",
      description: "Asks, then dies",
      task: :required,
      recovery: {:retry, 3}

    @schema %{"type" => "object", "properties" => %{"confirm" => %{"type" => "boolean"}}}

    @impl true
    def execute(_args, ctx) do
      {n, finish_from} = Sake.Tasks.RecoveryTest.next_run(ctx)

      case Sake.Elicit.form(ctx, "go", "Go?", @schema) do
        {:ok, %{"confirm" => true}} ->
          if n < finish_from, do: Process.sleep(:infinity), else: {:ok, "went on run #{n}"}

        other ->
          {:ok, "stopped: #{inspect(other)}"}
      end
    end
  end

  defmodule Export do
    use Sake.Tool,
      name: "export",
      description: "Hands its work to an export service",
      task: :required

    @impl true
    def execute(_args, ctx), do: {:external, "export-" <> ctx.task}
  end

  defmodule Server do
    use Sake.Server, name: "recovery", version: "1"
    tools [Flaky, Retried, Asker, Export]
  end

  # A durable queue: start/2 keeps the encoded job; the test runs it
  # later, from another process, as a queue's worker would.
  defmodule Queue do
    @behaviour Sake.Tasks.Runner

    @impl true
    def start(job, opts) do
      Agent.update(opts[:queue], &(&1 ++ [Job.encode(job)]))
      :ok
    end

    @impl true
    def cancel(task_id, opts) do
      send(opts[:test], {:queue_cancelled, task_id})
      :ok
    end

    @impl true
    def recovers?, do: true
  end

  @doc false
  def next_run(ctx) do
    %{test: test, runs: runs} = ctx.scope

    %{n: n, finish_from: finish_from} =
      Agent.get_and_update(runs, &{%{&1 | n: &1.n + 1}, %{&1 | n: &1.n + 1}})

    send(test, {:run, n, ctx.task, self()})
    {n, finish_from}
  end

  setup do
    {:ok, runs} = Agent.start_link(fn -> %{n: 0, finish_from: 2} end)
    config = Tasks.config()
    on_exit(fn -> :persistent_term.put({Tasks, :config}, config) end)

    # A job a queue carries is signed with Sake's secret.
    secret = :persistent_term.get({Sake, :secret_key_base}, nil)
    :persistent_term.put({Sake, :secret_key_base}, String.duplicate("k", 64))

    on_exit(fn ->
      if secret,
        do: :persistent_term.put({Sake, :secret_key_base}, secret),
        else: :persistent_term.erase({Sake, :secret_key_base})
    end)

    client = connect(Server, scope: %{test: self(), runs: runs}, capabilities: @caps)
    %{runs: runs, client: client}
  end

  defp finish_from(runs, k), do: Agent.update(runs, &%{&1 | finish_from: k})

  defp start_task(client, tool) do
    {:ok, {:task, %{"taskId" => id}}} = call_tool_async(client, tool, %{})
    id
  end

  # The node running the task goes away: its run (and the heartbeat linked
  # to it) dies, and its lease lapses.
  defp lose_run(id, pid) do
    Process.exit(pid, :kill)
    lapse(id)
  end

  defp lapse(id) do
    {:ok, _} =
      Tasks.update(Server, id, &%{&1 | lease_until: DateTime.add(Tasks.now(), -1, :second)})

    :ok
  end

  defp record(id) do
    {:ok, record} = Tasks.fetch(id)
    record
  end

  defp text(%{"status" => "completed", "result" => %{"content" => [%{"text" => text} | _]}}),
    do: text

  describe "a run that dies" do
    test "fails its task predictably by default", %{client: client} do
      id = start_task(client, "flaky")
      assert_receive {:run, 1, ^id, pid}
      assert %Record{status: :working, lease_owner: "run:" <> _} = record(id)

      lose_run(id, pid)
      Tasks.reap()

      assert {:ok, %{"status" => "failed", "error" => error}} = get_task(client, id)

      assert error == %{
               "code" => -32_603,
               "message" => "The task's worker stopped before the task ended.",
               "data" => %{"reason" => "worker_lost", "attempts" => 1}
             }

      # A second reap changes nothing: the task ended.
      Tasks.reap()
      assert {:ok, %{"status" => "failed"}} = get_task(client, id)
      refute_received {:run, 2, _, _}
    end

    test "runs again when its tool opted in", %{client: client} do
      id = start_task(client, "retried")
      assert_receive {:run, 1, ^id, pid}

      lose_run(id, pid)
      Tasks.reap()

      assert_receive {:run, 2, ^id, _pid}
      assert {:ok, task} = await_task(client, id)
      assert text(task) == "done on run 2"
      assert %Record{attempt: 2, lease_owner: nil} = record(id)
    end

    test "fails once its attempts are spent", %{client: client, runs: runs} do
      finish_from(runs, 99)
      id = start_task(client, "retried")
      assert_receive {:run, 1, ^id, pid}

      lose_run(id, pid)
      Tasks.reap()
      assert_receive {:run, 2, ^id, pid2}

      lose_run(id, pid2)
      Tasks.reap()

      assert {:ok, %{"status" => "failed", "error" => %{"data" => %{"attempts" => 2}}}} =
               get_task(client, id)
    end

    test "keeps waiting for the same input, and keeps the answers given", %{
      client: client,
      runs: runs
    } do
      finish_from(runs, 3)
      id = start_task(client, "asker")
      assert_receive {:run, 1, ^id, pid}

      assert {:ok, %{"status" => "input_required", "inputRequests" => %{"go" => _} = requests}} =
               await_task(client, id)

      # Lost while waiting: the next run asks the same question.
      lose_run(id, pid)
      Tasks.reap()
      assert_receive {:run, 2, ^id, pid2}

      assert {:ok, %{"status" => "input_required", "inputRequests" => ^requests}} =
               get_task(client, id)

      # Answered, then lost before the end: the next run gets the answer
      # without asking the client again.
      :ok =
        update_task(client, id, %{
          "go" => %{"action" => "accept", "content" => %{"confirm" => true}}
        })

      wait_for(fn -> record(id).status == :working and record(id).answers != %{} end)
      lose_run(id, pid2)
      Tasks.reap()

      assert_receive {:run, 3, ^id, _}
      assert {:ok, task} = await_task(client, id)
      assert text(task) == "went on run 3"
    end
  end

  describe "a durable queue" do
    setup do
      {:ok, queue} = Agent.start_link(fn -> [] end)
      config = Tasks.config()

      :persistent_term.put({Tasks, :config}, %{
        config
        | runner: {Queue, queue: queue, test: self()}
      })

      %{queue: queue}
    end

    defp next_job(queue) do
      [encoded | _] = Agent.get(queue, & &1)
      {:ok, job} = Job.decode(encoded)
      job
    end

    test "completes the task after the request that started it ended", %{
      client: client,
      queue: queue,
      runs: runs
    } do
      finish_from(runs, 1)
      id = start_task(client, "flaky")
      assert {:ok, %{"status" => "working"}} = get_task(client, id)
      refute_received {:run, _, _, _}

      # Later, in another process: the queue's worker.
      job = next_job(queue)
      assert job.task_id == id
      assert :completed = Task.await(Task.async(fn -> Tasks.run(job) end))
      assert {:ok, task} = await_task(client, id)
      assert text(task) == "done on run 1"
    end

    test "a job delivered twice runs the tool once at a time, and not after it ended", %{
      client: client,
      queue: queue,
      runs: runs
    } do
      id = start_task(client, "flaky")
      job = next_job(queue)

      first = Task.async(fn -> Tasks.run(job) end)
      assert_receive {:run, 1, ^id, _pid}

      # The first delivery still runs (it blocks): the second finds the
      # task held, and does nothing.
      assert {:skipped, :running} = Tasks.run(job)
      Task.shutdown(first, :brutal_kill)

      # The first delivery's process died; once its lease lapses, a
      # redelivery runs the tool, and one after the task ended does not.
      lapse(id)
      finish_from(runs, 1)
      assert :completed = Tasks.run(job)
      assert {:skipped, :ended} = Tasks.run(job)
      assert Agent.get(runs, & &1.n) == 2
    end

    test "recovers its own jobs: Sake's reaper leaves them alone", %{client: client, queue: queue} do
      id = start_task(client, "flaky")
      job = next_job(queue)
      spawn(fn -> Tasks.run(job) end)
      assert_receive {:run, 1, ^id, pid}

      lose_run(id, pid)
      Tasks.reap()
      assert %Record{status: :working} = record(id)

      # Left to the queue, which never comes: ended here, so no other test
      # reaps it.
      :ok = cancel_task(client, id)
    end

    test "a cancellation before the job runs: the runner is told, and the job finds the task ended",
         %{client: client, queue: queue} do
      id = start_task(client, "flaky")
      :ok = cancel_task(client, id)
      assert_received {:queue_cancelled, ^id}

      assert {:skipped, :ended} = Tasks.run(next_job(queue))
      refute_received {:run, _, _, _}
      assert {:ok, %{"status" => "cancelled"}} = get_task(client, id)
    end

    test "a cancellation while the job runs elsewhere: it ends cancelled", %{
      client: client,
      queue: queue
    } do
      id = start_task(client, "asker")
      job = next_job(queue)
      spawn(fn -> Tasks.run(job) end)
      assert_receive {:run, 1, ^id, pid}
      assert {:ok, %{"status" => "input_required"}} = await_task(client, id)

      # The run is on the node that received the cancel: it is stopped.
      ref = Process.monitor(pid)
      :ok = cancel_task(client, id)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
      assert {:ok, %{"status" => "cancelled"}} = get_task(client, id)
    end

    test "a job that runs after its task expired does nothing", %{client: client, queue: queue} do
      id = start_task(client, "flaky")

      {:ok, _} =
        Tasks.update(Server, id, &%{&1 | expires_at: DateTime.add(Tasks.now(), -1, :second)})

      assert {:skipped, :expired} = Tasks.run(next_job(queue))
      refute_received {:run, _, _, _}
    end

    test "a job signed with another secret, or tampered with, does not decode", %{
      client: client,
      queue: queue
    } do
      _ = start_task(client, "flaky")
      [encoded] = Agent.get(queue, & &1)
      assert {:ok, %Job{}} = Job.decode(encoded)
      assert :error = Job.decode(encoded <> "x")
      :persistent_term.put({Sake, :secret_key_base}, String.duplicate("o", 64))
      assert :error = Job.decode(encoded)
    end
  end

  describe "a stale run" do
    test "does not record its outcome over the run that replaced it", %{client: client} do
      id = start_task(client, "retried")
      assert_receive {:run, 1, ^id, first}
      %Record{lease_owner: stale} = record(id)

      # The first run stalls past its lease (it is still alive), and the
      # task is recovered: a second run completes it.
      lapse(id)
      Tasks.reap()
      assert_receive {:run, 2, ^id, _}
      assert {:ok, task} = await_task(client, id)
      assert text(task) == "done on run 2"

      # The stale run is still running, under a lease it no longer holds.
      assert Process.alive?(first)
      refute record(id).lease_owner == stale
      Process.exit(first, :kill)
    end
  end

  describe "an external job" do
    test "keeps the task working until the host reports it", %{client: client} do
      id = start_task(client, "export")
      handle = "export-" <> id
      wait_for(fn -> record(id).handle == handle end)
      assert %Record{status: :working, lease_owner: nil, lease_until: nil} = record(id)

      # Not an orphan: no lease to lapse.
      Tasks.reap()
      assert %Record{status: :working} = record(id)

      assert :ok = Tasks.progress(id, handle, 3, 10)
      assert {:ok, %{"statusMessage" => "3/10"}} = get_task(client, id)

      assert :error = Tasks.complete(id, "someone-else", {:ok, "nope"})
      assert :ok = Tasks.complete(id, handle, {:ok, %{"files" => 3}})

      assert {:ok,
              %{"status" => "completed", "result" => %{"structuredContent" => %{"files" => 3}}}} =
               get_task(client, id)

      # Once ended, a late report changes nothing.
      assert :error = Tasks.fail(id, handle, "too late")
    end

    test "fails, or is ignored once cancelled", %{client: client} do
      id = start_task(client, "export")
      wait_for(fn -> record(id).handle != nil end)
      assert :ok = Tasks.fail(id, "export-" <> id, "The export service refused.")

      assert {:ok,
              %{"status" => "failed", "error" => %{"message" => "The export service refused."}}} =
               get_task(client, id)

      other = start_task(client, "export")
      wait_for(fn -> record(other).handle != nil end)
      :ok = cancel_task(client, other)
      assert :error = Tasks.complete(other, "export-" <> other, {:ok, "late"})
      assert {:ok, %{"status" => "cancelled"}} = get_task(client, other)
    end
  end

  test "the runner and lease options are checked when tasks start" do
    assert_raise ArgumentError, ~r/is not a Sake.Tasks.Runner/, fn ->
      Tasks.start_link(runner: String)
    end

    assert_raise ArgumentError, ~r/lease: must be at least 30 ms/, fn ->
      Tasks.start_link(lease: 1)
    end
  end

  defp wait_for(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries > 0 -> Process.sleep(5) && wait_for(fun, tries - 1)
      true -> flunk("the condition never held")
    end
  end
end
