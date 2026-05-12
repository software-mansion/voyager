defmodule Voyager.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      VoyagerWeb.Telemetry,
      Voyager.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:voyager, :ecto_repos), skip: skip_migrations?()},
      {Phoenix.PubSub, name: Voyager.PubSub},
      VoyagerWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Voyager.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    VoyagerWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?(), do: System.get_env("RELEASE_NAME") == nil
end
