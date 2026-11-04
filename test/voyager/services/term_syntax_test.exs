defmodule Voyager.Services.TermSyntaxTest do
  # async: false because the setting and the node's syntax are cached for the whole VM.
  use Voyager.DataCase, async: false

  import Mox
  import Voyager.TestUtils, only: [reset_term_syntax: 1]

  alias Voyager.Services.TermSyntax
  alias Voyager.Settings

  @node :"peer@127.0.0.1"

  setup :verify_on_exit!
  setup :reset_term_syntax

  setup do
    TermSyntax.put_node(nil)
    on_exit(fn -> TermSyntax.put_node(nil) end)
  end

  defp connect(elixir_vsn_reply) do
    expect(Voyager.ErpcMock, :call, fn @node, :application, :get_key, [:elixir, :vsn], _timeout ->
      elixir_vsn_reply.()
    end)

    TermSyntax.put_node(@node)
  end

  defp lock(setting) do
    Application.put_env(:voyager, :term_syntax, setting)
    on_exit(fn -> Application.delete_env(:voyager, :term_syntax) end)
  end

  describe "current/0" do
    test "resolves auto to Erlang for a node without the Elixir application" do
      connect(fn -> :undefined end)

      assert TermSyntax.current() == :erlang
    end

    test "resolves auto to Elixir for a node running Elixir" do
      connect(fn -> {:ok, ~c"1.20.2"} end)

      assert TermSyntax.current() == :elixir
    end

    test "resolves auto to Elixir when the node cannot be asked" do
      connect(fn -> :erlang.error({:erpc, :noconnection}) end)

      assert TermSyntax.current() == :elixir
    end

    test "resolves auto to Elixir once the node is gone" do
      connect(fn -> :undefined end)
      TermSyntax.put_node(nil)

      assert TermSyntax.current() == :elixir
    end

    test "an explicit setting wins over the node" do
      connect(fn -> :undefined end)

      assert TermSyntax.save_setting(:elixir) == {:ok, :elixir}
      assert TermSyntax.current() == :elixir

      connect(fn -> {:ok, ~c"1.20.2"} end)

      assert TermSyntax.save_setting(:erlang) == {:ok, :erlang}
      assert TermSyntax.current() == :erlang
    end
  end

  describe "get_setting/0" do
    test "loads the saved setting on first read" do
      assert {:ok, _} = Settings.put(:term_syntax, :erlang)

      assert TermSyntax.get_setting() == :erlang
    end

    test "is auto when nothing is saved" do
      assert TermSyntax.get_setting() == :auto
    end

    test "is auto for an unknown saved value" do
      assert {:ok, _} = Settings.put(:term_syntax, :lfe)

      assert TermSyntax.get_setting() == :auto
    end

    test "prefers the application config" do
      assert {:ok, _} = Settings.put(:term_syntax, :elixir)
      lock(:erlang)

      assert TermSyntax.get_setting() == :erlang
    end
  end

  describe "save_setting/1" do
    test "saves and caches the setting" do
      assert TermSyntax.save_setting(:erlang) == {:ok, :erlang}

      assert Settings.get(:term_syntax) == :erlang
      assert TermSyntax.get_setting() == :erlang
    end

    test "rejects an unknown setting" do
      assert TermSyntax.save_setting("lfe") == {:error, :unsupported_choice}
      assert TermSyntax.get_setting() == :auto
    end

    test "leaves the database and the cache alone when the config locks the setting" do
      lock(:erlang)

      assert TermSyntax.setting_locked?()
      assert TermSyntax.save_setting(:elixir) == {:error, :locked}
      assert TermSyntax.get_setting() == :erlang
    end
  end
end
