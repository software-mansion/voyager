defmodule Voyager.Services.NodeConnector do
  @moduledoc "Connects to remote nodes via Erlang distribution."

  alias Voyager.Services.Distribution

  @spec connect(String.t(), String.t(), keyword()) :: {:ok, atom()} | {:error, term()}
  def connect(node_name, cookie, opts \\ []) do
    name_type = Keyword.get(opts, :name_type, :longnames)

    with :ok <- Distribution.ensure_distributed(name_type) do
      node = String.to_atom(node_name)
      :erlang.set_cookie(node, String.to_atom(cookie))
      connect_result = Node.connect(node)
      :erlang.set_cookie(node, :nocookie)

      case connect_result do
        true ->
          {:ok, node}

        false ->
          diagnose_failure(node_name)

        :ignored ->
          {:error, :not_distributed}
      end
    end
  end

  @spec disconnect(atom()) :: :ok
  def disconnect(node) do
    Node.disconnect(node)
    :ok
  end

  defp diagnose_failure(node_name) do
    case Distribution.split_node_name(node_name) do
      {:ok, name, host} -> diagnose_epmd_failure(name, host)
      _ -> {:error, :connection_failed}
    end
  end

  defp diagnose_epmd_failure(name, host) do
    host_arg =
      case :inet.parse_address(String.to_charlist(host)) do
        {:ok, tuple} -> tuple
        {:error, _} -> String.to_charlist(host)
      end

    task =
      Task.Supervisor.async_nolink(Voyager.TaskSupervisor, fn ->
        :erl_epmd.names(host_arg)
      end)

    result = Task.yield(task, 1_000) || Task.shutdown(task)

    case result do
      {:ok, {:ok, registered}} -> diagnose_registered_name(name, host, registered)
      _ -> {:error, :connection_failed}
    end
  end

  defp diagnose_registered_name(name, host, registered) do
    name_cl = String.to_charlist(name)

    case Enum.find(registered, fn {n, _port} -> n == name_cl end) do
      {_n, port} ->
        if port_alive?(host, port) do
          diagnose_registered_failure(host)
        else
          {:error, :node_unreachable}
        end

      nil ->
        {:error, :connection_failed}
    end
  end

  defp port_alive?(host, port) do
    {host_arg, opts} =
      case :inet.parse_address(String.to_charlist(host)) do
        {:ok, tuple} when tuple_size(tuple) == 8 -> {tuple, [:inet6]}
        {:ok, tuple} -> {tuple, [:inet]}
        {:error, _} -> {String.to_charlist(host), []}
      end

    case :gen_tcp.connect(host_arg, port, opts, 1_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end

  defp diagnose_registered_failure(host) do
    longnames? = :net_kernel.longnames() == true
    has_dots? = String.contains?(host, ".")

    cond do
      not longnames? and has_dots? ->
        {:error, :name_type_mismatch}

      longnames? and not has_dots? ->
        case :inet.parse_address(String.to_charlist(host)) do
          {:ok, _address} ->
            {:error, :bad_cookie}

          {:error, _} ->
            {:error, :name_type_mismatch}
        end

      true ->
        {:error, :bad_cookie}
    end
  end
end
