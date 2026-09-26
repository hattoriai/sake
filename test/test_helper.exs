{:ok, _} =
  Supervisor.start_link([Sake.Plug.Streams.child_spec([])],
    strategy: :one_for_one,
    name: SakeTest.Supervisor
  )

ExUnit.start()
