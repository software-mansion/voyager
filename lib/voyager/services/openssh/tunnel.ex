defmodule Voyager.Services.OpenSSH.Tunnel do
  @moduledoc """
  GenServer wrapping a persistent `ssh -L local_port:remote_host:remote_port -N`
  subprocess.

  `start_link/1` only returns `{:ok, pid}` once the local port accepts
  connections — eliminating the race between `ssh` binding the port and
  callers attempting to use it. If the readiness check times out, the process
  exits with `{:tunnel_not_ready, reason, stderr_tail}`.

  Stderr from the `ssh` subprocess is buffered (capped at `@stderr_buf_max`)
  and surfaced in the exit reason when the tunnel dies — useful for diagnosing
  authentication failures, port collisions, or host-key rejections.
  """

  use GenServer

  alias Voyager.Services.OpenSSH.Executor
  alias Voyager.Services.OpenSSH.KnownHosts

  require Logger

  @stderr_buf_max 4096
  @ready_timeout_ms 10_000
  @connect_timeout_s 10

  @type auth :: :agent | {:key, Path.t()}

  @type opts :: [
          user: String.t(),
          host: String.t(),
          ssh_port: pos_integer(),
          auth: auth(),
          local_port: pos_integer(),
          remote_host: String.t(),
          remote_port: pos_integer()
        ]

  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, Map.new(opts))
  end

  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 2_000)
    :ok
  end

  @impl GenServer
  def init(%{} = cfg) do
    Process.flag(:trap_exit, true)

    port =
      Port.open(
        {:spawn_executable, to_charlist(Executor.ssh!())},
        [:binary, :exit_status, :use_stdio, :stderr_to_stdout, args: build_args(cfg)]
      )

    case wait_for_port(cfg.local_port, @ready_timeout_ms) do
      :ok ->
        {:ok, %{port: port, buf: "", local_port: cfg.local_port}}

      {:error, reason} ->
        stderr = drain_messages(port, "")
        if Port.info(port) != nil, do: Port.close(port)
        {:stop, {:tunnel_not_ready, reason, stderr}}
    end
  end

  @impl GenServer
  def handle_info({port, {:data, data}}, %{port: port, buf: buf} = state) do
    {:noreply, %{state | buf: trim_buf(buf <> data)}}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port, buf: buf} = state) do
    Logger.warning("ssh tunnel exited code=#{code} stderr=#{inspect(buf)}")
    {:stop, {:tunnel_exited, code, buf}, %{state | port: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{port: nil}), do: :ok

  def terminate(_reason, %{port: port}) do
    if Port.info(port) != nil, do: Port.close(port)
    :ok
  end

  defp build_args(cfg) do
    [
      "-o",
      "StrictHostKeyChecking=yes",
      "-o",
      "UserKnownHostsFile=#{KnownHosts.path()}",
      "-o",
      "BatchMode=yes",
      "-o",
      "ConnectTimeout=#{@connect_timeout_s}",
      "-o",
      "ExitOnForwardFailure=yes",
      "-o",
      "ServerAliveInterval=15",
      "-o",
      "ServerAliveCountMax=3",
      "-p",
      "#{cfg.ssh_port}",
      "-L",
      "#{cfg.local_port}:#{cfg.remote_host}:#{cfg.remote_port}",
      "-N"
    ] ++ auth_args(cfg.auth) ++ ["#{cfg.user}@#{cfg.host}"]
  end

  defp auth_args(:agent), do: []
  defp auth_args({:key, path}), do: ["-i", path, "-o", "IdentitiesOnly=yes"]

  defp wait_for_port(port, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(port, deadline)
  end

  defp do_wait(port, deadline) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [active: false], 200) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, _} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(50)
          do_wait(port, deadline)
        end
    end
  end

  defp drain_messages(port, acc) do
    receive do
      {^port, {:data, data}} -> drain_messages(port, trim_buf(acc <> data))
    after
      100 -> acc
    end
  end

  defp trim_buf(buf) when byte_size(buf) <= @stderr_buf_max, do: buf

  defp trim_buf(buf),
    do: binary_part(buf, byte_size(buf) - @stderr_buf_max, @stderr_buf_max)
end
