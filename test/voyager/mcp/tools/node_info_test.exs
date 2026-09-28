defmodule Voyager.MCP.Tools.NodeInfoTest do
  # async: false because the tool reads the global `Voyager.NodeSession`.
  use ExUnit.Case, async: false

  import Mox

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Voyager.Fakes
  alias Voyager.MCP.Tools.NodeInfo

  @node :fake@localhost

  setup do
    Fakes.connect_node!(Fakes.node_session(node: @node, node_name: Atom.to_string(@node)))

    %{data: Fakes.node_data()}
  end

  test "renders the snapshot of the connected node", %{data: data} do
    Fakes.stub_erpc(data)

    payload = run()

    assert payload["node"] == Atom.to_string(@node)
    assert payload["system"]["otp_release"] == data.otp_release
    assert payload["memory"]["total"] == data.mem_total

    assert payload["limits"]["processes"] == %{
             "used" => data.process_count,
             "limit" => data.process_limit
           }
  end

  test "keeps the encoding the snapshot's own JSON.Encoder produces", %{data: data} do
    Fakes.stub_erpc(data)

    payload = run()

    assert {:ok, _collected_at, _offset} = DateTime.from_iso8601(payload["collected_at"])
    refute Map.has_key?(payload, "__struct__")
    refute Enum.any?(payload["applications"], &Map.has_key?(&1, "__struct__"))
  end

  test "returns an error when the snapshot fetch fails" do
    stub(Voyager.ErpcMock, :call, fn _node, _mod, _fun, _args ->
      :erlang.error({:erpc, :noconnection})
    end)

    stub(Voyager.ErpcMock, :call, fn _node, _mod, _fun, _args, _timeout ->
      :erlang.error({:erpc, :noconnection})
    end)

    assert {:reply, %Response{isError: true, content: [%{"text" => text}]}, %Frame{}} =
             NodeInfo.execute(%{}, %Frame{})

    assert text == "fetch failed: :noconnection"
  end

  defp run do
    assert {:reply, %Response{isError: false, content: [%{"text" => json}]}, %Frame{}} =
             NodeInfo.execute(%{}, %Frame{})

    JSON.decode!(json)
  end
end
