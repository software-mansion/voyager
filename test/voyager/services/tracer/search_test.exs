defmodule Voyager.Services.Tracer.SearchTest do
  # async: false because the pid test sets the global cached node id.
  use ExUnit.Case, async: false

  alias Voyager.Services.Tracer.Search

  @entry %{kind: :trace, seq: 0, pid: nil, process: nil, mfa: {Date, :leap_year?, 1}}

  describe "text/1" do
    test "joins the pid, process, mfa, args and value" do
      entry = %{@entry | pid: :c.pid(0, 1, 0), process: :my_server}

      assert Search.text(Map.put(entry, :args, [~D[2024-01-01]])) ==
               "#PID<0.1.0> :my_server Date.leap_year?/1 [~D[2024-01-01]]"

      assert Search.text(Map.put(entry, :value, true)) ==
               "#PID<0.1.0> :my_server Date.leap_year?/1 true"
    end

    test "shows pids in the traced node's local form, however deep" do
      on_exit(fn -> Voyager.Pid.put_node(nil) end)
      pid = remote_pid(1)
      [_prefix, node_id] = Regex.run(~r/^<(\d+)\./, Voyager.Pid.format(pid, :distribution))
      :persistent_term.put({Voyager.Pid, :node_id}, node_id)

      text = Search.text(%{@entry | pid: pid} |> Map.put(:args, [%{from: remote_pid(2)}]))
      assert text == "#PID<0.1.0> nil Date.leap_year?/1 [%{from: #PID<0.2.0>}]"
    end

    test "does not truncate long terms" do
      assert Search.text(Map.put(@entry, :args, [Enum.to_list(1..100)])) =~ "100]"
    end
  end

  describe "query/1" do
    test "folds the pids a user may paste to the local form" do
      on_exit(fn -> Voyager.Pid.put_node(nil) end)
      :persistent_term.put({Voyager.Pid, :node_id}, "7")

      assert Search.query("from #PID<7.1.0> to <7.2.0>, not <8.3.0>") ==
               "from #PID<0.1.0> to <0.2.0>, not <8.3.0>"
    end

    test "leaves other text alone" do
      assert Search.query("a_b %") == "a_b %"
    end
  end

  describe "filter/3" do
    setup do
      entries =
        for {args, seq} <- Enum.with_index(["HeLLo c", "other", "hello b", "hello a"]) do
          @entry
          |> Map.put(:seq, 3 - seq)
          |> Map.put(:args, [args])
        end

      %{entries: entries ++ [%{kind: :started, seq: 4, origin: :ui}]}
    end

    test "folds ASCII case only and skips non-trace entries", %{entries: entries} do
      assert %{entries: [%{seq: 3}, %{seq: 1}, %{seq: 0}], total: 3} =
               Search.filter(entries, "hello", limit: 10)

      assert %{entries: [], total: 0} = Search.filter(entries, "started", limit: 10)
      assert %{entries: [%{seq: 3}], total: 1} = Search.filter(entries, "LO C", limit: 10)
    end

    test "pages below :before with the total of every match", %{entries: entries} do
      assert %{entries: [%{seq: 3}, %{seq: 1}], total: 3} =
               Search.filter(entries, "hello", limit: 2)

      assert %{entries: [%{seq: 1}, %{seq: 0}], total: 3} =
               Search.filter(entries, "hello", before: 3, limit: 2)

      assert %{entries: [], total: 3} = Search.filter(entries, "hello", before: 0, limit: 2)
    end
  end

  defp remote_pid(id),
    do: :erlang.binary_to_term(<<131, 88, 100, 0, 8, "far@host", id::32, 0::32, 0::32>>)
end
