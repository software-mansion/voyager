# The BEAM target nodes and the app under test are started here, and stopped after the suite.
defmodule Voyager.E2E.Boot do
  @moduledoc false

  @port 4001

  def start do
    {_, 0} = System.cmd("bash", ["e2e/node.sh", "start"])
    wait_until(fn -> match?({_, 0}, rpc("erlang node []")) end, "target node")

    server =
      if port_open?() do
        # reuseExistingServer
        nil
      else
        server = start_server()
        wait_until(&port_open?/0, "server on port #{@port}")
        server
      end

    ExUnit.after_suite(fn _ -> stop(server) end)
  end

  defp start_server do
    command =
      ~s|ebin="$PWD/_build/e2e/lib/voyager/ebin" && | <>
        ~s|ELIXIR_ERL_OPTIONS="-proto_dist dual_tcp -epmd_module Elixir.Voyager.ProxyEpmd -pa $ebin" | <>
        "MIX_ENV=e2e exec mix phx.server"

    Port.open({:spawn_executable, System.find_executable("bash")}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: ["-c", command]
    ])
  end

  defp stop(server) do
    with port when is_port(port) <- server,
         {:os_pid, os_pid} <- Port.info(port, :os_pid) do
      System.cmd("kill", [Integer.to_string(os_pid)])
    end

    System.cmd("bash", ["e2e/node.sh", "stop"])
  end

  defp rpc(mfa),
    do:
      System.cmd("erl_call", ["-name", "test@127.0.0.1", "-c", "e2e_cookie", "-a", mfa],
        stderr_to_stdout: true
      )

  defp port_open? do
    case :gen_tcp.connect({127, 0, 0, 1}, @port, [], 500) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      _ ->
        false
    end
  end

  defp wait_until(fun, what, attempts \\ 120) do
    cond do
      fun.() -> :ok
      attempts == 0 -> raise "timed out waiting for #{what}"
      true -> Process.sleep(500) && wait_until(fun, what, attempts - 1)
    end
  end
end

Application.ensure_all_started(:playwright)
Voyager.E2E.Boot.start()

# Playwright's default test timeout is 30 s.
ExUnit.start(timeout: 30_000)
