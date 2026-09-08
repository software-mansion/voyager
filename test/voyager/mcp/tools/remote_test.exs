defmodule Voyager.MCP.Tools.RemoteTest do
  # async: false because the session and the injected rate limiter are global.
  use ExUnit.Case, async: false

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Voyager.Fakes
  alias Voyager.MCP.Tools.Remote
  alias Voyager.Pid
  alias Voyager.Services.NodeInfo.Snapshot
  alias Voyager.Services.RateLimiter

  setup do
    node = :fake@localhost
    Fakes.connect_node!(Fakes.node_session(node: node, node_name: Atom.to_string(node)))

    %{node: node}
  end

  describe "reply/2" do
    test "hands the connected node to the fetch function", %{node: node} do
      assert %{"node" => rendered} = run(fn n -> {:ok, %{node: n}} end)
      assert rendered == Atom.to_string(node)
    end

    test "renders a fetch failure" do
      assert error(fn _node -> {:error, :dead} end) == "fetch failed: :dead"
    end

    test "returns an error when no node is connected" do
      Fakes.put_session(nil)

      assert error(fn _node -> flunk("must not reach the node") end) ==
               "Not connected to any node"
    end
  end

  describe "rate limiting" do
    setup do
      start_supervised!({RateLimiter, name: EmptyBucket, config: %{high_capacity: 0}})
      Application.put_env(:voyager, :rate_limiter, EmptyBucket)
      on_exit(fn -> Application.delete_env(:voyager, :rate_limiter) end)

      :ok
    end

    test "reports the retry delay when the bucket is spent" do
      assert error(fn _node -> {:ok, %{}} end) =~ ~r/^rate limited, retry in \d+ms$/
    end

    test "never reaches the node when the bucket is spent" do
      assert error(fn _node -> flunk("must not reach the node") end) =~ "rate limited"
    end
  end

  describe "json rendering" do
    test "renders a pid in its textual form" do
      pid = Pid.parse("<0.123.0>")

      assert run(fn _node -> {:ok, %{pid: pid}} end) == %{"pid" => "<0.123.0>"}
    end

    test "renders a tuple as an array" do
      assert run(fn _node -> {:ok, %{mfa: {Enum, :map, 2}}} end) ==
               %{"mfa" => ["Elixir.Enum", "map", 2]}
    end

    test "inspects a term JSON cannot hold" do
      payload = %{binary: <<255>>, improper: [:a | :b], ref: make_ref()}

      assert %{"binary" => "<<255>>", "improper" => "[:a | :b]", "ref" => "#Reference" <> _} =
               run(fn _node -> {:ok, payload} end)
    end

    test "inspects a key JSON cannot hold" do
      assert run(fn _node -> {:ok, %{{:a, 1} => :value}} end) == %{"{:a, 1}" => "value"}
    end

    test "flattens a struct that has no encoder" do
      assert run(fn _node -> {:ok, %{set: MapSet.new([1])}} end) ==
               %{"set" => %{"__struct__" => "MapSet", "map" => %{"1" => []}}}
    end

    test "leaves a struct that has an encoder to its own encoder" do
      snapshot = %Snapshot{node: :fake@localhost, collected_at: DateTime.utc_now()}

      payload = run(fn _node -> {:ok, snapshot} end)

      assert {:ok, _, _} = DateTime.from_iso8601(payload["collected_at"])
      refute Map.has_key?(payload, "__struct__")
    end
  end

  defp reply(fun) do
    Remote.reply(fun, %Frame{})
  end

  defp run(fun) do
    assert {:reply, %Response{isError: false, content: [%{"text" => json}]}, %Frame{}} =
             reply(fun)

    JSON.decode!(json)
  end

  defp error(fun) do
    assert {:reply, %Response{isError: true, content: [%{"text" => text}]}, %Frame{}} = reply(fun)

    text
  end
end
