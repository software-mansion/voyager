defmodule Voyager.Repo.Migrations.CreateConnections do
  use Ecto.Migration

  def change do
    create table(:connections) do
      add :node_name, :string, null: false
      add :cookie, :string
      add :label, :string
      add :pinned, :boolean, default: false, null: false
      add :last_connected_at, :utc_datetime, null: false
      add :connected_count, :integer, default: 1, null: false

      timestamps()
    end

    create unique_index(:connections, [:node_name])
  end
end
