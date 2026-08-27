defmodule Voyager.VoyagerAgentTest do
  use ExUnit.Case, async: false

  @compile {:no_warn_undefined, :voyager_agent}
  @agent_module :voyager_agent
  @agent_path Path.join(:code.priv_dir(:voyager), "voyager_agent.erl")

  setup_all do
    {:ok, @agent_module, binary} = :compile.file(@agent_path, [:binary, :return_errors])
    {:module, @agent_module} = :code.load_binary(@agent_module, @agent_path, binary)

    on_exit(fn ->
      :code.purge(@agent_module)
    end)

    :ok
  end

  setup do
    on_exit(fn ->
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
    end)
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
end
