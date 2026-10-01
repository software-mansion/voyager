defmodule VoyagerWeb.ProcessInfoLive.QueryTest do
  use ExUnit.Case, async: true

  import Mox

  alias VoyagerWeb.ProcessInfoLive.Query

  setup :verify_on_exit!

  describe "resolve_pid/2" do
    test "resolves a <0.X.Y> string on the remote node itself" do
      pid = self()

      expect(Voyager.ErpcMock, :call, fn :demo@localhost,
                                         :erlang,
                                         :list_to_pid,
                                         [~c"<0.45.6>"],
                                         _timeout ->
        pid
      end)

      assert Query.resolve_pid(:demo@localhost, "<0.45.6>") == {:ok, pid}
    end

    test "surfaces an unreachable node without raising" do
      expect(Voyager.ErpcMock, :call, fn _node, _mod, _fun, _args, _timeout ->
        :erlang.error({:erpc, :noconnection})
      end)

      assert Query.resolve_pid(:demo@localhost, "<0.45.6>") == {:error, :noconnection}
    end

    test "rejects a normal-form string of a node this one is not connected to" do
      assert Query.resolve_pid(:demo@localhost, "<424242.45.6>") == {:error, :invalid_pid}
    end

    test "rejects a string that is not a pid" do
      assert Query.resolve_pid(:demo@localhost, "not-a-pid") == {:error, :invalid_pid}
    end
  end
end
