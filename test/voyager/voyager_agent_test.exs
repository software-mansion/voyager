defmodule Voyager.VoyagerAgentTest do
  use ExUnit.Case, async: false

  @compile {:no_warn_undefined, :voyager_agent}
  @agent_module :voyager_agent
  @agent_filename "voyager_agent.erl"

  setup do
    path =
      :voyager
      |> :code.priv_dir()
      |> Path.join(@agent_filename)
      |> String.to_charlist()

    {:ok, @agent_module, binary} = :compile.file(path, [:binary, :return_errors])
    {:module, @agent_module} = :code.load_binary(@agent_module, path, binary)

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

      # terminate/2 tail-calls purge_code/0, so no voyager_agent frame is left on
      # the stack and the final code:purge/1 has no reason to kill the agent. It
      # gets to exit with its own reason.
      assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}

      refute Process.whereis(@agent_module)
      assert false == Code.loaded?(@agent_module)
    end
  end
end
