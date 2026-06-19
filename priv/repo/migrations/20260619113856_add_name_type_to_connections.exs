defmodule Voyager.Repo.Migrations.AddNameTypeToConnections do
  use Ecto.Migration

  def change do
    alter table(:connections) do
      add :name_type, :string, null: false, default: "longnames"
    end
  end
end
