defmodule SakeTest.Repo do
  @moduledoc false
  use Ecto.Repo, otp_app: :sake, adapter: Ecto.Adapters.Postgres
end

defmodule SakeTest.SQLiteRepo do
  @moduledoc false
  # The Ecto stores on SQLite, which has no row locks (Sake.Auth.Store.Lock).
  use Ecto.Repo, otp_app: :sake, adapter: Ecto.Adapters.SQLite3
end

defmodule SakeTest.Migration do
  @moduledoc false
  use Ecto.Migration
  def up, do: Sake.Auth.Migration.up()
  def down, do: Sake.Auth.Migration.down()
end

defmodule SakeTest.TasksMigration do
  @moduledoc false
  use Ecto.Migration
  def up, do: Sake.Tasks.Migration.up()
  def down, do: Sake.Tasks.Migration.down()
end
