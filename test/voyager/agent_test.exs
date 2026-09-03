defmodule Voyager.AgentTest do
  use ExUnit.Case, async: false

  import Mox

  alias Voyager.Agent
  alias Voyager.Erpc

  @agent_module :voyager_agent

  setup :verify_on_exit!

  describe "install/1" do
    setup do
      on_exit(fn ->
        case Process.whereis(@agent_module) do
          nil ->
            :ok

          pid ->
            ref = Process.monitor(pid)
            Process.exit(pid, :kill)
            assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
        end

        :code.purge(@agent_module)
        :code.delete(@agent_module)
        :code.purge(@agent_module)
      end)

      :ok
    end

    test "refuses a node older than OTP 27 without sending any code" do
      expect(Voyager.ErpcMock, :call, fn _node, :erlang, :system_info, [:otp_release], _timeout ->
        ~c"26"
      end)

      assert {:error, {:agent_install_failed, {:otp_too_old, "26"}}} =
               Agent.install(:target@nohost)

      refute Code.loaded?(@agent_module)
    end

    test "reports an unparseable OTP release" do
      expect(Voyager.ErpcMock, :call, fn _node, :erlang, :system_info, [:otp_release], _timeout ->
        :unknown
      end)

      assert {:error, {:agent_install_failed, {:otp_unknown, :unknown}}} =
               Agent.install(:target@nohost)
    end

    test "wraps a failed register" do
      expect(Voyager.ErpcMock, :call, fn _node, :erlang, :system_info, [:otp_release], _timeout ->
        ~c"27"
      end)

      stub(Voyager.ErpcMock, :call, fn node, mod, fun, args, timeout ->
        case {mod, fun} do
          {@agent_module, :register} -> {:error, :unavailable}
          _ -> Erpc.Impl.call(node, mod, fun, args, timeout)
        end
      end)

      assert {:error, {:agent_install_failed, {:register_failed, :unavailable}}} =
               Agent.install(Node.self())
    end

    test "loads and registers the agent on a reachable node" do
      previous_erpc = Application.get_env(:voyager, :erpc)
      Application.put_env(:voyager, :erpc, Erpc.Impl)
      on_exit(fn -> Application.put_env(:voyager, :erpc, previous_erpc) end)

      assert :ok = Agent.install(Node.self())
      assert :sys.get_state(@agent_module) == {:state, %{Node.self() => true}}
    end

    test "surfaces a transport failure" do
      expect(Voyager.ErpcMock, :call, fn _node, :erlang, :system_info, [:otp_release], _timeout ->
        :erlang.error({:erpc, :noconnection})
      end)

      assert {:error, {:agent_install_failed, :noconnection}} = Agent.install(:target@nohost)
    end
  end

  describe "call/4" do
    test "returns the remote result" do
      expect(Voyager.ErpcMock, :call, fn _node, @agent_module, :proc_top, [1], _timeout ->
        {[], 0}
      end)

      assert {:ok, {[], 0}} = Agent.call(:target@nohost, :proc_top, [1], 1_000)
    end

    test "translates a missing agent into an :undef error" do
      expect(Voyager.ErpcMock, :call, fn _node, @agent_module, :proc_top, [1], _timeout ->
        :erlang.error({:exception, :undef, []})
      end)

      assert {:error, {:remote_exception, :undef}} =
               Agent.call(:target@nohost, :proc_top, [1], 1_000)
    end
  end
end
