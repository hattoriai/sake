defmodule SakeTest.Repo do
  @moduledoc false
  use Ecto.Repo, otp_app: :sake, adapter: Ecto.Adapters.Postgres
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
