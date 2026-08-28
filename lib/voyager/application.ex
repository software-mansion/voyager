defmodule Voyager.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    store_active_epmd_module()
    # Elixirkit installation here: https://hexdocs.pm/elixirkit/tauri.html#phoenix-tauri
    elixirkit_pubsub = System.get_env("ELIXIRKIT_PUBSUB")

    children = [
      Voyager.Vault,
      Voyager.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:voyager, :ecto_repos), skip: skip_migrations?()},
      Voyager.Telemetry,
      {Phoenix.PubSub, name: Voyager.PubSub},
      {Task.Supervisor, name: Voyager.TaskSupervisor},
      Voyager.ProxyEpmd.TunnelRegistry,
      Voyager.NodeSession,
      {ElixirKit.PubSub, connect: elixirkit_pubsub || :ignore, on_exit: fn -> System.stop() end},
      Voyager.RateLimiter,
      VoyagerWeb.Endpoint,
      Voyager.MCP,
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

  defp store_active_epmd_module do
    epmd_mod =
      case :init.get_argument(:epmd_module) do
        {:ok, [[mod_name] | _]} ->
          mod_name |> List.to_string() |> String.to_atom()

        _ ->
          :erl_epmd
      end

    :persistent_term.put(:voyager_epmd_module, epmd_mod)
  end
end
