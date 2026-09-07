defmodule Voyager.MCP.Tools.ProcessListTest do
  # async: false because the tool runs against the real `:erpc` impl and the
  # global `Voyager.NodeSession`, both swapped here.
  use ExUnit.Case, async: false

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Voyager.Fakes
  alias Voyager.MCP.Tools.ProcessList
  alias Voyager.Pid
  alias Voyager.Services.RateLimiter

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
    test "rejects an unrankable sort_by" do
      assert {:error, _errors} = ProcessList.mcp_schema(%{"sort_by" => "registered_name"})
    end

    test "rejects a limit past the maximum" do
      assert {:error, _errors} = ProcessList.mcp_schema(%{"limit" => 101})
    end

    test "rejects an attribute outside the allowed set" do
      assert {:error, _errors} = ProcessList.mcp_schema(%{"attrs" => ["messages"]})
    end

    test "defaults the limit, ranking and columns" do
      assert {:ok, params} = ProcessList.mcp_schema(%{})

      assert params.limit == 25
      assert params.sort_by == "memory"
      assert params.direction == "desc"
      assert params.attrs == ~w(memory reductions message_queue_len registered_name)
    end
  end

  describe "execute/2" do
    test "ranks the local processes and renders pids that parse back" do
      %{"total_scanned" => total, "processes" => processes} = run(%{"limit" => 5})

      assert total > length(processes)
      assert length(processes) == 5
      assert Enum.all?(processes, &is_pid(Pid.parse(&1["pid"])))

      memory = Enum.map(processes, & &1["memory"])
      assert memory == Enum.sort(memory, :desc)
    end

    test "ranks smallest first on an ascending direction" do
      %{"processes" => processes} = run(%{"limit" => 5, "direction" => "asc"})

      memory = Enum.map(processes, & &1["memory"])
      assert memory == Enum.sort(memory)
    end

    test "returns only the requested columns, plus the ranked one" do
      %{"processes" => processes} =
        run(%{"limit" => 3, "sort_by" => "reductions", "attrs" => ["registered_name"]})

      assert Enum.all?(
               processes,
               &(Enum.sort(Map.keys(&1)) == ~w(pid reductions registered_name))
             )
    end

    test "filters on a searched registered name" do
      name = :"mcp_process_list_#{System.unique_integer([:positive])}"
      Process.register(self(), name)

      %{"processes" => processes} =
        run(%{"limit" => 5, "attrs" => ["registered_name"], "search" => "mcp_process_list"})

      assert [%{"registered_name" => registered_name, "pid" => pid}] = processes
      assert registered_name == Atom.to_string(name)
      assert Pid.parse(pid) == self()
    end

    test "returns an error when no node is connected" do
      Fakes.put_session(nil)

      assert error(%{"limit" => 1}) == "Not connected to any node"
    end

    test "reports the retry delay when the rate limit is spent" do
      on_exit(fn ->
        :sys.replace_state(RateLimiter, &%{&1 | tokens_high: &1.config.high_capacity})
      end)

      :sys.replace_state(RateLimiter, &%{&1 | tokens_high: 0})

      assert error(%{"limit" => 1}) =~ "rate limited, retry in"
    end
  end

  defp execute(params) do
    {:ok, validated} = ProcessList.mcp_schema(params)
    ProcessList.execute(validated, %Frame{})
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
