defmodule Voyager.MCP.Tools.ProcessInfoTest do
  # async: false because the tool reads the global `Voyager.NodeSession`.
  use ExUnit.Case, async: false

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Voyager.Fakes
  alias Voyager.MCP.Tools.ProcessInfo
  alias Voyager.Pid

  @pid "<0.500.0>"

  # The remote calls `ProcessInfo.fetch/2` issues for the `info` section.
  @info ~w(process_info wordsize)a

  setup do
    node = :fake@localhost
    Fakes.connect_node!(Fakes.node_session(node: node, node_name: Atom.to_string(node)))

    :ok
  end

  describe "schema validation" do
    test "requires a pid" do
      assert {:error, _errors} = ProcessInfo.mcp_schema(%{})
    end

    test "rejects an unknown section" do
      assert {:error, _errors} = ProcessInfo.mcp_schema(%{"pid" => @pid, "section" => "mailbox"})
    end

    test "rejects a list of sections" do
      assert {:error, _errors} =
               ProcessInfo.mcp_schema(%{"pid" => @pid, "section" => ["links", "state"]})
    end

    test "reads the info section by default" do
      assert {:ok, %{section: "info", limit: 25}} = ProcessInfo.mcp_schema(%{"pid" => @pid})
    end
  end

  describe "info section" do
    test "renders the fixed-size attributes" do
      Fakes.stub_erpc(only(@info))

      info = run(%{"pid" => @pid})

      assert info["pid"] == @pid
      assert info["parent"] == "<0.123.0>"
      assert info["group_leader"] == "<0.64.0>"
      assert info["status"] == "waiting"
      assert info["memory"] == 2_672
      assert info["catch_level"] == 0
      assert info["gc_fullsweep_after"] == 65_535
    end

    test "renders the stacktrace frames readably" do
      Fakes.stub_erpc(only(@info))

      assert run(%{"pid" => @pid})["current_stacktrace"] == [
               ["gen_server", "loop", 7, [["file", "gen_server.erl"], ["line", 1194]]]
             ]
    end

    test "converts the word-counted sizes to bytes using the remote's word size" do
      Fakes.stub_erpc(only(@info, wordsize: 4))

      info = run(%{"pid" => @pid})

      assert info["stack_and_heap_size"] == 233 * 4
      assert info["heap_size"] == 233 * 4
      assert info["stack_size"] == 11 * 4
      assert info["gc_min_heap_size"] == 233 * 4
    end

    test "renders an unset registered name and trace token as null" do
      Fakes.stub_erpc(only(@info))

      info = run(%{"pid" => @pid})

      assert info["registered_name"] == nil
      assert info["sequential_trace_token"] == nil
    end

    test "reports a process that is already gone" do
      Fakes.stub_erpc(only(@info, process_info: :undefined))

      assert error(%{"pid" => @pid}) == "fetch failed: :dead"
    end
  end

  describe "unbounded sections" do
    test "reads the named section and nothing else" do
      Fakes.stub_erpc(only(~w(proc_links)a))

      assert run(%{"pid" => @pid, "section" => "links"}) == %{
               "pid" => @pid,
               "links" => %{"total" => 1, "truncated?" => false, "items" => ["<0.201.0>"]}
             }
    end

    test "reads each section from its own remote call" do
      for section <- ~w(monitors monitored_by dictionary label state messages) do
        Fakes.stub_erpc(only([:"proc_#{section}"]))

        assert %{^section => _} = run(%{"pid" => @pid, "section" => section})
      end
    end

    test "renders the remote's truncation flags" do
      Fakes.stub_erpc(only(~w(proc_messages)a))

      assert %{"messages" => messages} = run(%{"pid" => @pid, "section" => "messages"})
      assert messages == %{"total" => 2, "truncated?" => true, "items" => ["first"]}
    end

    test "fails the call when the section could not be read" do
      Fakes.stub_erpc(only(~w(proc_links)a, proc_links: {:error, :dead}))

      assert error(%{"pid" => @pid, "section" => "links"}) == "fetch failed: :dead"
    end

    test "encodes a term that JSON cannot represent" do
      pid = Pid.parse("<0.201.0>")
      term = %{term: %{<<255>> => {:tuple, pid}}, truncated: false}

      Fakes.stub_erpc(only(~w(proc_state)a, proc_state: {:ok, term}))

      assert %{"state" => %{"term" => rendered}} = run(%{"pid" => @pid, "section" => "state"})
      assert rendered == %{inspect(<<255>>) => ["tuple", "<0.201.0>"]}
    end
  end

  describe "pid parsing" do
    test "accepts the inspect form of a pid" do
      Fakes.stub_erpc(only(@info))

      assert %{"pid" => @pid} = run(%{"pid" => "#PID" <> @pid})
    end

    test "rejects a malformed pid before touching the node" do
      assert error(%{"pid" => "not-a-pid"}) == "Malformed pid: not-a-pid"
    end
  end

  # A fixture holding only the listed remote calls: `Fakes.erpc_reply/4` raises
  # on anything else, so a second fetch in one call fails the test.
  defp only(keys, overrides \\ []) do
    overrides
    |> Fakes.process_data()
    |> Map.take(keys)
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
