defmodule Voyager.MCP.Tools.ProcessInfoTest do
  # async: false because the tool runs against the real `:erpc` impl and the
  # global `Voyager.NodeSession`, both swapped here.
  use ExUnit.Case, async: false

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Voyager.Fakes
  alias Voyager.MCP.Tools.ProcessInfo
  alias Voyager.MCP.Tools.ProcessList
  alias Voyager.Pid

  setup_all do
    path = :voyager |> :code.priv_dir() |> Path.join("voyager_agent.erl") |> String.to_charlist()
    {:ok, module, binary} = :compile.file(path, [:binary])
    {:module, ^module} = :code.load_binary(module, path, binary)

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)

    :ok
  end

  setup do
    previous = Application.get_env(:voyager, :erpc)
    Application.put_env(:voyager, :erpc, Voyager.Erpc.Impl)
    on_exit(fn -> Application.put_env(:voyager, :erpc, previous) end)

    node = Node.self()
    Fakes.connect_node!(Fakes.node_session(node: node, node_name: Atom.to_string(node)))

    :ok
  end

  describe "schema validation" do
    test "requires a pid" do
      assert {:error, _errors} = ProcessInfo.mcp_schema(%{})
    end

    test "rejects an unknown section" do
      assert {:error, _errors} =
               ProcessInfo.mcp_schema(%{"pid" => "<0.1.0>", "include" => ["mailbox"]})
    end

    test "includes nothing by default" do
      assert {:ok, %{include: [], limit: 25}} = ProcessInfo.mcp_schema(%{"pid" => "<0.1.0>"})
    end
  end

  describe "execute/2" do
    test "returns the fixed-size attributes of a live process" do
      pid = start_supervised!({Agent, fn -> :state end})

      info = run(%{"pid" => Pid.display(pid)})

      assert info["pid"] == Pid.display(pid)
      assert is_integer(info["memory"])
      assert info["status"] in ~w(waiting runnable running suspended garbage_collecting)
      assert is_pid(Pid.parse(info["parent"]))
      assert is_pid(Pid.parse(info["group_leader"]))
    end

    test "fetches only the requested sections" do
      pid = start_supervised!({Agent, fn -> %{count: 1} end})

      info = run(%{"pid" => Pid.display(pid), "include" => ["links", "state"]})

      assert %{"total" => 1, "truncated?" => false, "items" => [_ | _]} = info["links"]
      assert %{"truncated?" => false, "term" => %{"count" => 1}} = info["state"]
      refute Map.has_key?(info, "messages")
      refute Map.has_key?(info, "dictionary")
      refute Map.has_key?(info, "label")
    end

    test "encodes a term that JSON cannot represent" do
      me = self()
      pid = start_supervised!({Agent, fn -> %{<<255>> => {:tuple, me}} end})

      info = run(%{"pid" => Pid.display(pid), "include" => ["state"]})

      assert %{"term" => term} = info["state"]
      assert term == %{inspect(<<255>>) => ["tuple", Pid.display(me)]}
    end

    test "accepts a pid string returned by process_list" do
      %{"processes" => [%{"pid" => pid_string} | _]} = process_list()

      assert %{"pid" => ^pid_string} = run(%{"pid" => pid_string})
    end

    test "accepts the inspect form of a pid" do
      pid = start_supervised!({Agent, fn -> :state end})

      assert %{"pid" => rendered} = run(%{"pid" => inspect(pid)})
      assert rendered == Pid.display(pid)
    end

    test "rejects a malformed pid before touching the node" do
      Fakes.put_session(nil)

      assert error(%{"pid" => "not-a-pid"}) == "Malformed pid: not-a-pid"
    end

    test "reports a process that is already gone" do
      pid = start_supervised!({Agent, fn -> :state end})
      pid_string = Pid.display(pid)
      :ok = stop_supervised!(Agent)

      assert error(%{"pid" => pid_string}) == "fetch failed: :dead"
    end

    test "returns an error when no node is connected" do
      Fakes.put_session(nil)

      assert error(%{"pid" => Pid.display(self())}) == "Not connected to any node"
    end
  end

  defp execute(params) do
    {:ok, validated} = ProcessInfo.mcp_schema(params)
    ProcessInfo.execute(validated, %Frame{})
  end

  defp run(params) do
    assert {:reply, %Response{isError: false, content: [%{"text" => json}]}, %Frame{}} =
             execute(params)

    JSON.decode!(json)
  end

  defp error(params) do
    assert {:reply, %Response{isError: true, content: [%{"text" => text}]}, %Frame{}} =
             execute(params)

    text
  end

  defp process_list do
    {:ok, params} = ProcessList.mcp_schema(%{"limit" => 1})

    assert {:reply, %Response{isError: false, content: [%{"text" => json}]}, %Frame{}} =
             ProcessList.execute(params, %Frame{})

    JSON.decode!(json)
  end
end
