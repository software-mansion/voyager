defmodule Voyager.Services.Ets.FetchAgentLiveTest do
  use ExUnit.Case, async: false

  @compile {:no_warn_undefined, :voyager_agent}

  alias Voyager.Erpc
  alias Voyager.Services.Ets.Fetch
  alias Voyager.Services.Ets.Sanitize

  @agent_module :voyager_agent
  @agent_filename "voyager_agent.erl"

  setup do
    Erpc.bind_impl(Voyager.Erpc.Impl)

    path =
      :voyager
      |> :code.priv_dir()
      |> Path.join(@agent_filename)
      |> String.to_charlist()

    :code.purge(@agent_module)
    :code.delete(@agent_module)
    :code.purge(@agent_module)

    {:ok, @agent_module, binary} = :compile.file(path, [:binary, :return_errors])
    {:module, @agent_module} = :code.load_binary(@agent_module, path, binary)

    on_exit(fn ->
      :code.purge(@agent_module)
      :code.delete(@agent_module)
      :code.purge(@agent_module)
    end)

    :ok
  end

  test "select_chunk/3 returns agent-truncated records matching Sanitize.term/1" do
    name = unique_name()
    :ets.new(name, [:named_table, :public, :set])
    on_exit(fn -> safe_delete(name) end)

    blob = :binary.copy(<<"z">>, 600)
    :ets.insert(name, {:row, blob})

    assert {:ok, chunk} = Fetch.select_chunk(Node.self(), name, 10)
    assert chunk.via == :agent
    assert chunk.records == [{:row, Sanitize.term(blob)}]
    assert chunk.records == [{:row, @agent_module.truncate_term(blob)}]
  end

  test "lookup/3 double-sanitize is a no-op on agent-truncated records" do
    name = unique_name()
    :ets.new(name, [:named_table, :public, :set])
    on_exit(fn -> safe_delete(name) end)

    :ets.insert(name, {:k, Enum.to_list(1..60)})

    assert {:ok, chunk} = Fetch.lookup(Node.self(), name, :k)
    assert chunk.via == :agent
    assert [{:k, truncated}] = chunk.records
    assert truncated == Sanitize.term(Enum.to_list(1..60))
    assert truncated == Sanitize.term(truncated)
  end

  test "select_chunk/3 leaves the ETS continuation unsanitized" do
    name = unique_name()
    :ets.new(name, [:named_table, :public, :set])
    on_exit(fn -> safe_delete(name) end)

    for i <- 1..25, do: :ets.insert(name, {i, :binary.copy(<<"a">>, 600)})

    assert {:ok, page} = Fetch.select_chunk(Node.self(), name, 10)
    assert page.via == :agent
    assert is_list(page.records)
    assert page.continuation
    refute match?({:"$voyager_truncated", _, _, _}, page.continuation)
  end

  defp unique_name do
    :"voyager_ets_#{System.unique_integer([:positive])}"
  end

  defp safe_delete(id) do
    :ets.delete(id)
  rescue
    ArgumentError -> :ok
  end
end
