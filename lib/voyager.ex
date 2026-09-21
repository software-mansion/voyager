defmodule Voyager do
  @moduledoc """
  Voyager — runtime introspection tool for BEAM nodes.

  Connect to a remote Erlang/Elixir node and inspect its processes,
  supervision tree, ETS tables, and runtime state.
  """

  @version Mix.Project.config()[:version]

  @spec version() :: String.t()
  def version, do: @version
end
