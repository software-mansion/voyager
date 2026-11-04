defmodule Voyager.Repo.Migrations.CreateTraceSessionsAndEvents do
  use Ecto.Migration

  def change do
    create table(:trace_sessions) do
      add :origin, :string, null: false
      add :status, :string, null: false
      add :node, :string
      add :config, :map
      add :stop_reason, :binary
      add :traces, :integer, default: 0, null: false
      add :dropped, :integer, default: 0, null: false
      add :bytes, :integer, default: 0, null: false
      add :started_at, :utc_datetime_usec
      add :stopped_at, :utc_datetime_usec

      timestamps()
    end

    create table(:trace_session_events) do
      add :session_id, references(:trace_sessions, on_delete: :delete_all), null: false
      add :seq, :integer, null: false
      add :kind, :string, null: false
      add :at, :utc_datetime_usec, null: false
      add :origin, :string
      add :node, :string
      add :config, :map
      add :reason, :binary
      add :traces, :integer
      add :dropped, :integer
    end

    create unique_index(:trace_session_events, [:session_id, :seq])

    create table(:trace_events) do
      add :session_id, references(:trace_sessions, on_delete: :delete_all), null: false
      add :seq, :integer, null: false
      add :at, :utc_datetime_usec, null: false
      add :type, :string, null: false
      add :pid, :binary, null: false
      add :process, :binary, null: false
      add :module, :string, null: false
      add :function, :string, null: false
      add :arity, :integer, null: false
      add :args, :binary
      add :value, :binary
      add :truncated, :boolean
      add :duration_us, :integer
      add :search_text, :text, null: false
    end

    create unique_index(:trace_events, [:session_id, :seq])
  end
end
