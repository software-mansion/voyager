defmodule Voyager.ErpcTest do
  use ExUnit.Case, async: true

  import Mox

  alias Voyager.Erpc

  setup :verify_on_exit!

  describe "safe_call/5" do
    test "wraps a successful remote result" do
      expect(Voyager.ErpcMock, :call, fn :n, :m, :f, [], 1_000 -> :ok end)
      assert {:ok, :ok} = Erpc.safe_call(:n, :m, :f, [], 1_000)
    end

    test "formats erpc failures as {:error, reason}" do
      expect(Voyager.ErpcMock, :call, fn _, _, _, _, _ ->
        :erlang.error({:erpc, :timeout})
      end)

      assert {:error, :timeout} = Erpc.safe_call(:n, :m, :f, [], 1_000)
    end
  end

  test "bind_impl/1 is process-local and does not change application env" do
    assert Erpc.impl() == Voyager.ErpcMock
    Erpc.bind_impl(Voyager.Erpc.Impl)
    assert Erpc.impl() == Voyager.Erpc.Impl
    assert Application.get_env(:voyager, :erpc) == Voyager.ErpcMock
  end

  describe "format_error/2" do
    test "maps erpc timeout and noconnection to atoms" do
      assert Erpc.format_error(:error, {:erpc, :timeout}) == {:error, :timeout}
      assert Erpc.format_error(:error, {:erpc, :noconnection}) == {:error, :noconnection}
    end

    test "maps remote exceptions and other erpc reasons" do
      assert Erpc.format_error(:error, {:exception, :badarg, []}) ==
               {:error, {:remote_exception, :badarg}}

      assert Erpc.format_error(:error, {:erpc, :notsup}) == {:error, {:erpc, :notsup}}
    end

    test "maps remaining error, exit, and throw" do
      assert Erpc.format_error(:error, :other) == {:error, :other}
      assert Erpc.format_error(:exit, :killed) == {:error, {:remote_exit, :killed}}
      assert Erpc.format_error(:throw, :nope) == {:error, {:remote_throw, :nope}}
    end
  end
end
