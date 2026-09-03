defmodule Voyager.Test.VoyagerAgentFixture do
  @moduledoc """
  Compiles and loads `priv/voyager_agent.erl` for live tests.

  Call `load!/0` from `setup` (the test process) so `on_exit` is valid.
  Unload kills a leftover registered pid, then purges the module.
  """

  @module :voyager_agent
  @filename "voyager_agent.erl"

  @spec load!() :: :ok
  def load! do
    unload()

    path =
      :voyager
      |> :code.priv_dir()
      |> Path.join(@filename)
      |> String.to_charlist()

    {:ok, @module, binary} = :compile.file(path, [:binary, :return_errors])
    {:module, @module} = :code.load_binary(@module, path, binary)

    ExUnit.Callbacks.on_exit(&unload/0)
    :ok
  end

  defp unload do
    case Process.whereis(@module) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        end
    end

    :code.purge(@module)
    :code.delete(@module)
    :code.purge(@module)
  end
end
