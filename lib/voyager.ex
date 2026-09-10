defmodule Voyager do
  @moduledoc """
  Voyager — runtime introspection tool for BEAM nodes.

  Connect to a remote Erlang/Elixir node and inspect its processes,
  supervision tree, ETS tables, and runtime state.
  """

  @version Mix.Project.config()[:version]

  @spec version() :: String.t()
  def version, do: @version

  @doc """
  Returns whether the running app came from a local (developer) build.

  Set from the `VOYAGER_DEV_BUILD` environment variable when the app is built —
  see `config/config.exs`.
  """
  @spec dev_build?() :: boolean()
  def dev_build?, do: Application.get_env(:voyager, :dev_build?, false)
end
