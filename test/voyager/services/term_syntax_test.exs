defmodule Voyager.Services.TermSyntaxTest do
  # async: false because the setting and the node's syntax are cached for the whole VM.
  use Voyager.DataCase, async: false

  import Mox

  alias Voyager.Services.TermSyntax
  alias Voyager.Settings

  @node :"peer@127.0.0.1"

  setup :verify_on_exit!

  setup do
    setting = TermSyntax.cached_setting()
    TermSyntax.put_node(nil)

    on_exit(fn ->
      TermSyntax.put_setting(setting)
      TermSyntax.put_node(nil)
    end)
  end

  defp connect(elixir_vsn_reply) do
    expect(Voyager.ErpcMock, :call, fn @node, :application, :get_key, [:elixir, :vsn], _timeout ->
      elixir_vsn_reply.()
    end)

    TermSyntax.put_node(@node)
  end

  describe "current/0" do
    test "resolves auto to Erlang for a node without the Elixir application" do
      TermSyntax.put_setting(:auto)
      connect(fn -> :undefined end)

      assert TermSyntax.current() == :erlang
    end

    test "resolves auto to Elixir for a node running Elixir" do
      TermSyntax.put_setting(:auto)
      connect(fn -> {:ok, ~c"1.20.2"} end)

      assert TermSyntax.current() == :elixir
    end

    test "resolves auto to Elixir when the node cannot be asked" do
      TermSyntax.put_setting(:auto)
      connect(fn -> :erlang.error({:erpc, :noconnection}) end)

      assert TermSyntax.current() == :elixir
    end

    test "resolves auto to Elixir once the node is gone" do
      TermSyntax.put_setting(:auto)
      connect(fn -> :undefined end)
      TermSyntax.put_node(nil)

      assert TermSyntax.current() == :elixir
    end

    test "an explicit setting wins over the node" do
      connect(fn -> :undefined end)

      TermSyntax.put_setting(:elixir)
      assert TermSyntax.current() == :elixir

      connect(fn -> {:ok, ~c"1.20.2"} end)

      TermSyntax.put_setting(:erlang)
      assert TermSyntax.current() == :erlang
    end
  end

  describe "load_setting/0" do
    test "caches the saved setting" do
      assert {:ok, _} = Settings.put(:term_syntax, :erlang)
      TermSyntax.put_setting(:auto)

      TermSyntax.load_setting()

      assert TermSyntax.cached_setting() == :erlang
    end

    test "falls back to auto when nothing is saved" do
      TermSyntax.put_setting(:erlang)

      TermSyntax.load_setting()

      assert TermSyntax.cached_setting() == :auto
    end

    test "falls back to auto for an unknown saved value" do
      assert {:ok, _} = Settings.put(:term_syntax, :lfe)
      TermSyntax.put_setting(:erlang)

      TermSyntax.load_setting()

      assert TermSyntax.cached_setting() == :auto
    end

    test "prefers the application config" do
      assert {:ok, _} = Settings.put(:term_syntax, :elixir)
      Application.put_env(:voyager, :term_syntax, :erlang)
      on_exit(fn -> Application.delete_env(:voyager, :term_syntax) end)

      TermSyntax.load_setting()

      assert TermSyntax.cached_setting() == :erlang
    end
  end
end
