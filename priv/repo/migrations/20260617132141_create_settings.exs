defmodule Voyager.Repo.Migrations.CreateSettings do
  use Ecto.Migration

  def change do
    create table(:settings) do
      add :key, :string, null: false
      add :value, :string, null: false

      timestamps()
    end

    create unique_index(:settings, [:key])
  end
end
