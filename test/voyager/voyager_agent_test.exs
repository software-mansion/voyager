defmodule Voyager.VoyagerAgentTest do
  @moduledoc "Test for voyager_agent.erl"
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

      :code.purge(@agent_module)
      :code.delete(@agent_module)
      :code.purge(@agent_module)
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

    test "restarts instead of exiting when the agent dies during the call" do
      # Stand in for the agent so the name is registered and whereis/1 succeeds,
      # then die without replying. That is the race window: register/1 has
      # already committed to do_register/2 when the process disappears.
      stub =
        spawn(fn ->
          receive do
            {:"$gen_call", _from, {:register, _node}} -> exit(:normal)
          end
        end)

      Process.register(stub, @agent_module)
      ref = Process.monitor(stub)

      assert {:ok, pid} = @agent_module.register(Node.self())

      assert_receive {:DOWN, ^ref, :process, ^stub, :normal}
      assert is_pid(pid)
      assert pid == Process.whereis(@agent_module)
    end
  end

  describe "exit signals" do
    test "shuts down on an exit signal so terminate/2 can purge the module" do
      {:ok, pid} = @agent_module.register(Node.self())
      ref = Process.monitor(pid)

      Process.exit(pid, :shutdown)

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      refute Process.whereis(@agent_module)
      assert false == Code.loaded?(@agent_module)
    end
  end

  describe "nodedown" do
    test "keeps other registrations when one parent goes down" do
      parent = Node.self()
      other = :other@localhost
      {:ok, pid} = @agent_module.register(parent)

      :sys.replace_state(pid, fn {:state, nodes} ->
        {:state, Map.put(nodes, other, true)}
      end)

      send(pid, {:nodedown, parent})
      _ = :sys.get_state(pid)

      assert Process.whereis(@agent_module) == pid
      assert :sys.get_state(pid) == {:state, %{other => true}}
      assert Code.loaded?(@agent_module)
    end

    test "stops and unloads the module when the last parent goes down" do
      parent = Node.self()
      {:ok, pid} = @agent_module.register(parent)
      ref = Process.monitor(pid)

      send(pid, {:nodedown, parent})

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      refute Process.whereis(@agent_module)
      assert false == Code.loaded?(@agent_module)
    end
  end
end
