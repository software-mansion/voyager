defmodule DualTcpDistFilterTest do
  use ExUnit.Case, async: true

  @moduletag :integration
  @moduletag :capture_log
  @cookie ~c"dual-tcp-filter-test"

  setup do
    {_output, 0} = System.cmd("epmd", ["-daemon"])
    ebin = :voyager |> :code.lib_dir() |> Path.join("ebin") |> String.to_charlist()

    victim =
      start_peer(
        :victim,
        [~c"-proto_dist", ~c"dual_tcp", ~c"-dist_listen", ~c"false", ~c"-hidden"] ++
          [~c"-pa", ebin]
      )

    target = start_peer(:target, [])

    true = :peer.call(victim.peer, :net_kernel, :connect_node, [target.node])

    probe = :peer.call(victim.peer, :erlang, :spawn, [:timer, :sleep, [:infinity]])
    true = :peer.call(victim.peer, :erlang, :register, [:dual_tcp_probe, probe])

    %{victim: victim, target: target, probe: probe}
  end

  test "calls from the filtered node to the target still work", %{victim: victim, target: target} do
    assert :peer.call(victim.peer, :erpc, :call, [target.node, :erlang, :node, []]) == target.node
    assert :peer.call(victim.peer, :rpc, :call, [target.node, :erlang, :node, []]) == target.node
  end

  test "the target cannot run code on the filtered node", ctx do
    %{victim: victim, target: target, probe: probe} = ctx
    run = [:erlang, :send, [:dual_tcp_probe, :pwned]]
    file = Path.join(System.tmp_dir!(), "dual_tcp_#{System.unique_integer([:positive])}")
    attacker = :peer.call(target.peer, :erlang, :whereis, [:init])
    group_leader = :peer.call(victim.peer, :erlang, :group_leader, [])

    assert {:error, {:erpc, :timeout}} =
             peer_call(target.peer, :erpc, :call, [victim.node | run] ++ [500])

    assert {:badrpc, :timeout} = peer_call(target.peer, :rpc, :call, [victim.node | run] ++ [500])

    send_from(target, {:rex, victim.node}, {attacker, {:call, :erlang, :send, tl(run), :user}})

    send_from(
      target,
      {:net_kernel, victim.node},
      {:"$gen_call", {attacker, make_ref()}, {:spawn, :erlang, :send, tl(run), group_leader}}
    )

    send_from(
      target,
      {:file_server_2, victim.node},
      {:"$gen_call", {attacker, make_ref()}, {:open, file, [:write]}}
    )

    send_from(
      target,
      group_leader,
      {:io_request, attacker, make_ref(), {:put_chars, :unicode, :erlang, :send, tl(run)}}
    )

    :peer.call(target.peer, :erlang, :exit, [probe, :kill])

    assert :peer.call(victim.peer, :erpc, :call, [target.node, :erlang, :node, []]) == target.node

    assert :peer.call(victim.peer, :erlang, :process_info, [probe, :message_queue_len]) ==
             {:message_queue_len, 0}

    refute File.exists?(file)
  end

  defp start_peer(prefix, args) do
    name = :"#{prefix}_#{System.unique_integer([:positive])}"

    {:ok, peer, node} =
      :peer.start(%{
        name: name,
        host: ~c"127.0.0.1",
        longnames: true,
        connection: :standard_io,
        args: [~c"-setcookie", @cookie | args]
      })

    on_exit(fn -> stop_peer(peer) end)
    %{peer: peer, node: node}
  end

  defp peer_call(peer, mod, fun, args) do
    :peer.call(peer, mod, fun, args, 5_000)
  catch
    :error, reason -> {:error, reason}
  end

  defp send_from(peer, dest, message), do: :peer.call(peer.peer, :erlang, :send, [dest, message])

  defp stop_peer(peer) do
    :peer.stop(peer)
  catch
    :exit, _ -> :ok
  end
end
