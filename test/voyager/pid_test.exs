defmodule Voyager.PidTest do
  # async: false because the format and the node id are cached for the whole VM.
  use Voyager.DataCase, async: false

  import Mox

  alias Voyager.Pid
  alias Voyager.Settings

  @node :"peer@127.0.0.1"

  doctest Voyager.Pid

  setup :verify_on_exit!

  setup do
    format = Pid.cached_format()
    Pid.put_node(nil)

    on_exit(fn ->
      Pid.put_format(format)
      Pid.put_node(nil)
    end)
  end

  # NEW_PID_EXT: a pid of `node` without connecting to it.
  defp pid_on(node, id) do
    name = Atom.to_string(node)
    :erlang.binary_to_term(<<131, 88, 119, byte_size(name), name::binary, id::32, 0::32, 1::32>>)
  end

  defp distribution(pid), do: pid |> :erlang.pid_to_list() |> List.to_string()

  defp connect(node) do
    expect(Voyager.ErpcMock, :call, fn ^node, :erlang, :self, [], _timeout -> pid_on(node, 1) end)
    Pid.put_node(node)
  end

  describe "parse/1" do
    test "reads a pid from its text form, with or without the #PID prefix" do
      text = distribution(self())

      assert Pid.parse(text) == self()
      assert Pid.parse("#PID" <> text) == self()
    end

    test "returns nil for text that is not a pid" do
      assert Pid.parse("not a pid") == nil
      assert Pid.parse("<1.2>") == nil
    end
  end

  describe "format/2" do
    test "keeps the distribution form of pids and pid strings" do
      pid = pid_on(@node, 45)

      assert Pid.format(pid, :distribution) == distribution(pid)
      assert Pid.format(distribution(pid), :distribution) == distribution(pid)
    end

    test "shortens only the connected node's pids in the local form" do
      connect(@node)
      pid = pid_on(@node, 45)
      other = pid_on(:"other@127.0.0.1", 45)

      assert Pid.format(pid, :local) == "<0.45.0>"
      assert Pid.format(distribution(pid), :local) == "<0.45.0>"
      assert Pid.format(other, :local) == distribution(other)
    end

    test "shortens any pid in the local form while no node is connected" do
      assert Pid.format(pid_on(@node, 45), :local) == "<0.45.0>"
    end

    test "leaves text that is not a pid unchanged" do
      assert Pid.format("Elixir.MyApp.Worker", :local) == "Elixir.MyApp.Worker"
    end

    test "defaults to the cached format" do
      pid = pid_on(@node, 45)

      Pid.put_format(:local)
      assert Pid.format(pid) == "<0.45.0>"

      Pid.put_format(:distribution)
      assert Pid.format(pid) == distribution(pid)
    end
  end

  describe "inspect_fun/2" do
    test "renders nested pids in the cached format" do
      Pid.put_format(:local)
      pid = pid_on(@node, 45)

      assert inspect({:ok, [pid]}, inspect_fun: &Pid.inspect_fun/2) == "{:ok, [#PID<0.45.0>]}"
    end
  end

  describe "put_node/1" do
    test "caches the id the node's pids print with" do
      connect(@node)

      [id] = Regex.run(~r/^<(\d+)\./, distribution(pid_on(@node, 0)), capture: :all_but_first)
      assert Pid.cached_node_id() == id
    end

    test "caches no id when the node cannot be reached" do
      expect(Voyager.ErpcMock, :call, fn @node, :erlang, :self, [], _timeout ->
        :erlang.error({:erpc, :noconnection})
      end)

      assert Pid.put_node(@node) == :ok
      assert Pid.cached_node_id() == nil
    end

    test "clears the id" do
      connect(@node)
      Pid.put_node(nil)

      assert Pid.cached_node_id() == nil
    end
  end

  describe "put_format/1" do
    test "stores the format cached_format/0 returns" do
      Pid.put_format(:local)
      assert Pid.cached_format() == :local

      Pid.put_format(:distribution)
      assert Pid.cached_format() == :distribution
    end
  end

  describe "load_format/0" do
    test "caches the saved setting" do
      assert {:ok, _} = Settings.put(:pid_format, :local)
      Pid.put_format(:distribution)

      Pid.load_format()

      assert Pid.cached_format() == :local
    end

    test "falls back to distribution when nothing is saved" do
      Pid.put_format(:local)

      Pid.load_format()

      assert Pid.cached_format() == :distribution
    end

    test "falls back to distribution for an unknown saved value" do
      assert {:ok, _} = Settings.put(:pid_format, :bogus)
      Pid.put_format(:local)

      Pid.load_format()

      assert Pid.cached_format() == :distribution
    end

    test "prefers the application config" do
      assert {:ok, _} = Settings.put(:pid_format, :distribution)
      Application.put_env(:voyager, :pid_format, :local)
      on_exit(fn -> Application.delete_env(:voyager, :pid_format) end)

      Pid.load_format()

      assert Pid.cached_format() == :local
    end
  end
end
