defmodule Voyager.AgentTest do
  use ExUnit.Case, async: false

  import Mox

  alias Voyager.Agent
  alias Voyager.Erpc
  alias Voyager.NodeSession
  alias Voyager.NodeSession.Session
  alias Voyager.Test.FakeConnector
  alias Voyager.Test.VoyagerAgentFixture

  @agent_module Voyager.Agent.module()

  setup :verify_on_exit!

  describe "install/1" do
    setup do: on_exit(&VoyagerAgentFixture.unload/0)

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

    test "keeps an in-flight agent call alive when another Voyager connects" do
      previous_erpc = Application.get_env(:voyager, :erpc)
      Application.put_env(:voyager, :erpc, Erpc.Impl)
      on_exit(fn -> Application.put_env(:voyager, :erpc, previous_erpc) end)

      node = Node.self()
      test_pid = self()

      # Never answers, so the agent worker stays parked inside agent code -- what
      # a reload would purge.
      victim =
        spawn(fn ->
          receive do
            {:system, _from, _request} ->
              send(test_pid, :probed)

              receive do
                :release -> :ok
              end
          end
        end)

      assert :ok = Agent.install(node)

      task = Task.async(fn -> Agent.call(node, :proc_state, [victim, 1_000, 5_000], 10_000) end)
      assert_receive :probed

      assert :ok = Agent.install(node)
      assert :ok = Agent.install(node)

      send(victim, :release)
      assert {:ok, {:error, :no_state}} = Task.await(task)
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

    test "translates a missing agent into an :undef error and drops the session" do
      node = :target@nohost
      seed_session(node)
      Phoenix.PubSub.subscribe(Voyager.PubSub, NodeSession.topic())

      expect(Voyager.ErpcMock, :call, fn _node, @agent_module, :proc_top, [1], _timeout ->
        :erlang.error({:exception, :undef, []})
      end)

      assert {:error, {:remote_exception, :undef}} = Agent.call(node, :proc_top, [1], 1_000)

      assert_receive {:connector_disconnect, ^node}
      assert_receive {:node_disconnected, ^node}
      refute NodeSession.connected?()
    end
  end

  defp seed_session(node) do
    previous_state = :sys.get_state(NodeSession)
    on_exit(fn -> :sys.replace_state(NodeSession, fn _ -> previous_state end) end)

    session = %Session{
      node: node,
      node_name: to_string(node),
      cookie: "secret",
      connected_at: DateTime.utc_now(),
      connector: FakeConnector,
      meta: %{test_pid: self()}
    }

    :sys.replace_state(NodeSession, &Map.put(&1, :session, session))
  end
end
