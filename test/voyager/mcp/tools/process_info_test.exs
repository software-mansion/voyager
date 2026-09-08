defmodule Voyager.MCP.Tools.ProcessInfoTest do
  # async: false because the tool reads the global `Voyager.NodeSession`.
  use ExUnit.Case, async: false

  import Mox

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Voyager.Fakes
  alias Voyager.MCP.Tools.ProcessInfo
  alias Voyager.Pid

  @pid "<0.500.0>"

  setup do
    node = :fake@localhost
    Fakes.connect_node!(Fakes.node_session(node: node, node_name: Atom.to_string(node)))

    %{data: Fakes.process_data()}
  end

  describe "schema validation" do
    test "requires a pid" do
      assert {:error, _errors} = ProcessInfo.mcp_schema(%{})
    end

    test "rejects an unknown section" do
      assert {:error, _errors} =
               ProcessInfo.mcp_schema(%{"pid" => @pid, "include" => ["mailbox"]})
    end

    test "includes nothing by default" do
      assert {:ok, %{include: [], limit: 25}} = ProcessInfo.mcp_schema(%{"pid" => @pid})
    end
  end

  describe "execute/2" do
    test "renders the fixed-size attributes", %{data: data} do
      Fakes.stub_erpc(data)

      info = run(%{"pid" => @pid})

      assert info["pid"] == @pid
      assert info["parent"] == "<0.123.0>"
      assert info["group_leader"] == "<0.64.0>"
      assert info["status"] == "waiting"
      assert info["memory"] == 2_672
      assert info["catch_level"] == 0
      assert info["gc_fullsweep_after"] == 65_535
    end

    test "converts the word-counted sizes to bytes using the remote's word size" do
      Fakes.stub_erpc(Fakes.process_data(wordsize: 4))

      info = run(%{"pid" => @pid})

      assert info["stack_and_heap_size"] == 233 * 4
      assert info["heap_size"] == 233 * 4
      assert info["stack_size"] == 11 * 4
      assert info["gc_min_heap_size"] == 233 * 4
    end

    test "renders an unset registered name and trace token as null", %{data: data} do
      Fakes.stub_erpc(data)

      info = run(%{"pid" => @pid})

      assert info["registered_name"] == nil
      assert info["sequential_trace_token"] == nil
    end

    test "fetches only the requested sections" do
      Fakes.stub_erpc(only(~w(proc_links proc_state)a))

      info = run(%{"pid" => @pid, "include" => ["links", "state"]})

      assert info["links"] == %{"total" => 1, "truncated?" => false, "items" => ["<0.201.0>"]}
      assert info["state"] == %{"truncated?" => false, "term" => %{"count" => 1}}
      refute Map.has_key?(info, "messages")
      refute Map.has_key?(info, "dictionary")
      refute Map.has_key?(info, "monitors")
      refute Map.has_key?(info, "label")
    end

    test "fetches a section once when it is named twice" do
      test = self()
      data = only(~w(proc_links)a)

      stub(Voyager.ErpcMock, :call, fn _node, mod, fun, args, _timeout ->
        if fun == :proc_links, do: send(test, :fetched)
        Fakes.erpc_reply(mod, fun, args, data)
      end)

      assert %{"links" => %{"total" => 1}} =
               run(%{"pid" => @pid, "include" => ["links", "links"]})

      assert_received :fetched
      refute_received :fetched
    end

    test "reports a section that could not be read" do
      Fakes.stub_erpc(only(~w(proc_links)a, proc_links: {:error, :dead}))

      assert %{"links" => %{"error" => ":dead"}} = run(%{"pid" => @pid, "include" => ["links"]})
    end

    test "encodes a term that JSON cannot represent" do
      pid = Pid.parse("<0.201.0>")
      term = %{term: %{<<255>> => {:tuple, pid}}, truncated: false}

      Fakes.stub_erpc(only(~w(proc_state)a, proc_state: {:ok, term}))

      assert %{"state" => %{"term" => rendered}} = run(%{"pid" => @pid, "include" => ["state"]})
      assert rendered == %{inspect(<<255>>) => ["tuple", "<0.201.0>"]}
    end

    test "accepts the inspect form of a pid", %{data: data} do
      Fakes.stub_erpc(data)

      assert %{"pid" => @pid} = run(%{"pid" => "#PID" <> @pid})
    end

    test "rejects a malformed pid before touching the node" do
      assert error(%{"pid" => "not-a-pid"}) == "Malformed pid: not-a-pid"
    end

    test "reports a process that is already gone" do
      Fakes.stub_erpc(Fakes.process_data(process_info: :undefined))

      assert error(%{"pid" => @pid}) == "fetch failed: :dead"
    end
  end

  defp only(sections, overrides \\ []) do
    overrides
    |> Fakes.process_data()
    |> Map.take([:wordsize, :process_info | sections])
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
end
