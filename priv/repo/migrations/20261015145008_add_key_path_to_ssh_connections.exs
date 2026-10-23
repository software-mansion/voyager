defmodule Voyager.Repo.Migrations.AddKeyPathToSshConnections do
  use Ecto.Migration

  def change do
    alter table(:ssh_connections) do
      add :key_path, :string
    end
  end
end
