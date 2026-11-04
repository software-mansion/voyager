defmodule Voyager.Repo.Migrations.AddAgentSocketPathToSshConnections do
  use Ecto.Migration

  def change do
    alter table(:ssh_connections) do
      add :agent_socket_path, :string
    end
  end
end
