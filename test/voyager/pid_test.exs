defmodule Voyager.PidTest do
  # async: false because the format and the node id are cached for the whole VM.
  use Voyager.DataCase, async: false

  import Mox
  import Voyager.TestUtils, only: [reset_pid_format: 1]

  alias Voyager.Pid
  alias Voyager.Settings

  @node :"peer@127.0.0.1"

  doctest Voyager.Pid

  setup :verify_on_exit!
  setup :reset_pid_format

  setup do
    Pid.put_node(nil)
    on_exit(fn -> Pid.put_node(nil) end)
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

    test "keeps every pid in the local form while no node is connected" do
      pid = pid_on(@node, 45)

      assert Pid.format(pid, :local) == distribution(pid)
    end

    test "leaves text that is not a pid unchanged" do
      connect(@node)
      not_pid = "<#{Pid.cached_node_id()}.not a pid>"

      assert Pid.format("Elixir.MyApp.Worker", :local) == "Elixir.MyApp.Worker"
      assert Pid.format(not_pid, :local) == not_pid
    end

    test "defaults to the format setting" do
      connect(@node)
      pid = pid_on(@node, 45)

      assert Pid.save_setting(:local) == :ok
      assert Pid.format(pid) == "<0.45.0>"

      assert Pid.save_setting(:distribution) == :ok
      assert Pid.format(pid) == distribution(pid)
    end
  end

  describe "inspect_fun/2" do
    test "renders nested pids in the format setting" do
      connect(@node)
      assert Pid.save_setting(:local) == :ok
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

  defp lock_format(format) do
    Application.put_env(:voyager, :pid_format, format)
    on_exit(fn -> Application.delete_env(:voyager, :pid_format) end)
  end

  describe "get_setting/0" do
    test "loads the saved setting on first read" do
      assert {:ok, _} = Settings.put(:pid_format, :local)

      assert Pid.get_setting() == :local
    end

    test "is distribution when nothing is saved" do
      assert Pid.get_setting() == :distribution
    end

    test "is distribution for an unknown saved value" do
      assert {:ok, _} = Settings.put(:pid_format, :bogus)

      assert Pid.get_setting() == :distribution
    end

    test "prefers the application config" do
      assert {:ok, _} = Settings.put(:pid_format, :distribution)
      lock_format(:local)

      assert Pid.get_setting() == :local
    end
  end

  describe "save_setting/1" do
    test "saves and caches the format" do
      assert Pid.save_setting(:local) == :ok

      assert Settings.get(:pid_format) == :local
      assert Pid.get_setting() == :local
    end

    test "leaves the database and the cache alone when the config locks the format" do
      lock_format(:local)

      assert Pid.setting_locked?()
      assert Pid.save_setting(:distribution) == {:error, :locked}
      assert Pid.get_setting() == :local
    end
  end

  describe "resolve/2" do
    test "resolves a <0.X.Y> string on the remote node itself" do
      pid = self()

      expect(Voyager.ErpcMock, :call, fn :demo@localhost,
                                         :erlang,
                                         :list_to_pid,
                                         [~c"<0.45.6>"],
                                         _timeout ->
        pid
      end)

      assert Pid.resolve(:demo@localhost, "<0.45.6>") == {:ok, pid}
    end

    test "resolves a #PID<0.X.Y> string on the remote node itself" do
      pid = self()

      expect(Voyager.ErpcMock, :call, fn :demo@localhost,
                                         :erlang,
                                         :list_to_pid,
                                         [~c"<0.45.6>"],
                                         _timeout ->
        pid
      end)

      assert Pid.resolve(:demo@localhost, "#PID<0.45.6>") == {:ok, pid}
    end

    test "surfaces an unreachable node without raising" do
      expect(Voyager.ErpcMock, :call, fn _node, _mod, _fun, _args, _timeout ->
        :erlang.error({:erpc, :noconnection})
      end)

      assert Pid.resolve(:demo@localhost, "<0.45.6>") == {:error, :noconnection}
    end

    test "rejects a normal-form string of a node this one is not connected to" do
      assert Pid.resolve(:demo@localhost, "<424242.45.6>") == {:error, :invalid_pid}
    end

    test "rejects a string that is not a pid" do
      assert Pid.resolve(:demo@localhost, "not-a-pid") == {:error, :invalid_pid}
    end
  end
end
