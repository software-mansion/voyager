defmodule Voyager.Repo.Migrations.CreateSshConnections do
  use Ecto.Migration

  def change do
    create table(:ssh_connections) do
      add :ssh_user, :string, null: false
      add :ssh_host, :string, null: false
      add :ssh_port, :integer, null: false, default: 22
      add :node_name, :string, null: false
      add :cookie, :binary
      add :name_type, :string, null: false, default: "longnames"
      add :auth_method, :string, null: false, default: "agent"
      add :password, :binary
      add :epmd_port, :integer, null: false, default: 4369
      add :pinned, :boolean, null: false, default: false
      add :last_connected_at, :utc_datetime, null: false

      timestamps()
    end

    create unique_index(:ssh_connections, [:ssh_user, :ssh_host, :ssh_port, :node_name])
  end
end
