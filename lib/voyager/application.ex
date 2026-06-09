defmodule Voyager.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Elixirkit installation here: https://hexdocs.pm/elixirkit/tauri.html#phoenix-tauri
    elixirkit_pubsub = System.get_env("ELIXIRKIT_PUBSUB")

    children = [
      Voyager.Telemetry,
      Voyager.Vault,
      Voyager.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:voyager, :ecto_repos), skip: skip_migrations?()},
      {Phoenix.PubSub, name: Voyager.PubSub},
      {Task.Supervisor, name: Voyager.TaskSupervisor},
      Voyager.NodeSession,
      {ElixirKit.PubSub, connect: elixirkit_pubsub || :ignore, on_exit: fn -> System.stop() end},
      VoyagerWeb.Endpoint,
      {Task, fn -> if elixirkit_pubsub, do: ElixirKit.PubSub.broadcast("messages", "ready") end}
    ]

    opts = [strategy: :one_for_one, name: Voyager.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    VoyagerWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?, do: System.get_env("RELEASE_NAME") == nil
end
