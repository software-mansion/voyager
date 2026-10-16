defmodule Voyager.Repo.Migrations.AddKeyFileToSshConnections do
  use Ecto.Migration

  def change do
    alter table(:ssh_connections) do
      add :key_path, :string
      add :passphrase, :binary
    end
  end
end
