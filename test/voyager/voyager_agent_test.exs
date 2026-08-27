defmodule Voyager.VoyagerAgentTest do
  use ExUnit.Case, async: false

  @compile {:no_warn_undefined, :voyager_agent}
  @agent_module :voyager_agent

  setup do
    load_agent()

    on_exit(fn ->
      stop_agent()
      purge_agent()
    end)

    :ok
  end

  describe "register/1" do
    test "starts the agent and returns its pid" do
      assert {:ok, pid} = @agent_module.register(Node.self())
      assert pid == Process.whereis(@agent_module)
    end

    test "is idempotent for the same node" do
      assert {:ok, pid} = @agent_module.register(Node.self())
      assert {:ok, ^pid} = @agent_module.register(Node.self())
      assert :sys.get_state(@agent_module) == {:state, %{Node.self() => true}}
    end
  end

  describe "exit signals" do
    test "shuts down on an exit signal so terminate/2 can purge the module" do
      {:ok, pid} = @agent_module.register(Node.self())
      ref = Process.monitor(pid)

      Process.exit(pid, :shutdown)

      assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}
      # wait for the code to be purged
      Process.sleep(200)
      refute Process.whereis(@agent_module)
      assert false == :code.is_loaded(@agent_module)
    end
  end

  defp load_agent do
    path =
      :voyager
      |> :code.priv_dir()
      |> Path.join("voyager_agent.erl")
      |> String.to_charlist()

    {:ok, @agent_module, binary} = :compile.file(path, [:binary, :return_errors])
    {:module, @agent_module} = :code.load_binary(@agent_module, path, binary)
  end

  # Only purge: the agent deletes the module itself from terminate/2, and a
  # competing :code.delete/1 here would race that. setup/0 reloads it anyway.
  defp purge_agent do
    :code.purge(@agent_module)
  end

  defp stop_agent do
    case Process.whereis(@agent_module) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        end
    end
  end
end
