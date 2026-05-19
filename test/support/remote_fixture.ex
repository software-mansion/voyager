defmodule Voyager.Test.RemoteFixture do
  @moduledoc """
  Helper for spawning a controlled remote BEAM node with a deterministic
  supervision tree for testing `:erpc`-driven inspectors.

  Usage in tests:

      setup do
        peer = RemoteFixture.start_peer!()
        RemoteFixture.load_fixture_app!(peer)
        RemoteFixture.start_fixture_app!(peer)
        on_exit(fn -> RemoteFixture.stop_peer!(peer) end)
        {:ok, peer: peer}
      end
  """

  @doc """
  Starts a peer BEAM node. Ensures distribution is running on the test node
  first. Returns `%{peer: peer_pid, node: node_atom}`.
  """
  def start_peer!(opts \\ []) do
    ensure_distributed!()

    rand = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    name = Keyword.get(opts, :name, :"peer_#{rand}")

    {:ok, peer_pid, peer_node} =
      :peer.start_link(%{
        name: name,
        host: ~c"127.0.0.1",
        connection: :standard_io
      })

    %{peer: peer_pid, node: peer_node}
  end

  @doc """
  Stops the peer node gracefully. Handles the normal `:shutdown` exit that
  `:peer.stop/1` produces via `sys.terminate`.
  """
  def stop_peer!(%{peer: peer_pid}) do
    try do
      :peer.stop(peer_pid)
    catch
      :exit, {:shutdown, _} -> :ok
      :exit, :shutdown -> :ok
    end
  end

  @doc """
  Pushes the test compile paths to the peer so that fixture modules are
  available there.
  """
  def load_fixture_app!(%{node: node}) do
    paths = :code.get_path()
    :erpc.call(node, :code, :add_paths, [paths])
  end

  @doc """
  Registers and starts the fixture OTP application on the peer node.
  Uses `:application.load/1` at runtime to avoid needing a `.app` file.
  Syncs via `:sys.get_state/1` to confirm boot — no `Process.sleep`.
  """
  def start_fixture_app!(%{node: node}) do
    app_spec =
      {:application, :voyager_fixture,
       [
         {:description, ~c"Voyager test fixture app"},
         {:vsn, ~c"0.1.0"},
         {:modules,
          [
            Voyager.Test.FixtureApp,
            Voyager.Test.FixtureApp.RootSupervisor,
            Voyager.Test.FixtureApp.MidSupervisor,
            Voyager.Test.FixtureApp.Worker
          ]},
         {:registered, []},
         {:applications, [:kernel, :stdlib]},
         {:mod, {Voyager.Test.FixtureApp, []}}
       ]}

    :erpc.call(node, :application, :load, [app_spec])
    {:ok, _apps} = :erpc.call(node, :application, :ensure_all_started, [:voyager_fixture])

    # Sync: confirm boot completed without sleep
    :erpc.call(node, :sys, :get_state, [Voyager.Test.FixtureApp.RootSupervisor])

    :ok
  end

  @doc """
  Kills a named supervisor on the peer node.
  Uses two `:erpc` calls: one to resolve the name to a PID, one to send the
  exit signal. No anonymous function is shipped to the peer.
  """
  def kill_supervisor!(%{node: node}, name) do
    pid = :erpc.call(node, :erlang, :whereis, [name])
    :erpc.call(node, :erlang, :exit, [pid, :kill])
  end

  # Ensures the local test node is running in distributed mode.
  # Uses longnames with a stable name so multiple test runs don't conflict.
  defp ensure_distributed! do
    unless Node.alive?() do
      {:ok, _} = :net_kernel.start([:"voyager_test@127.0.0.1", :longnames])
    end
  end
end
