defmodule Voyager.Services.NodeConnector do
  @moduledoc "Connects to remote nodes via Erlang distribution."

  alias Voyager.Settings

  require Logger

  @spec connect(String.t(), String.t(), keyword()) :: {:ok, atom()} | {:error, term()}
  def connect(node_name, cookie, opts \\ []) do
    name_type = Keyword.get(opts, :name_type, :longnames)

    with :ok <- ensure_distributed(name_type) do
      node = String.to_atom(node_name)
      :erlang.set_cookie(node, String.to_atom(cookie))

      case Node.connect(node) do
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

  defp ensure_distributed(name_type) when name_type in [:longnames, :shortnames] do
    cond do
      not Node.alive?() ->
        start_distribution(name_type)

      matches_name_type?(name_type) and distribution_name_matches?() ->
        :ok

      true ->
        case :net_kernel.stop() do
          :ok -> start_distribution(name_type)
          {:error, reason} -> {:error, {:net_kernel_stop, reason}}
        end
    end
  end

  defp ensure_distributed(_name_type) do
    {:error, :invalid_name_type}
  end

  defp matches_name_type?(:longnames), do: :net_kernel.longnames() == true
  defp matches_name_type?(:shortnames), do: :net_kernel.longnames() == false

  defp start_distribution(name_type) do
    node_name = distribution_name()

    case :net_kernel.start(node_name, %{name_domain: name_type, hidden: true}) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, pid}} ->
        Logger.warning(
          "net_kernel.start/2 returned {:already_started, #{inspect(pid)}} " <>
            "for #{inspect(node_name)} name_type=#{inspect(name_type)}"
        )

        :ok

      {:error, reason} ->
        {:error, {:net_kernel, reason}}
    end
  end

  defp distribution_name_matches? do
    distributed_node_name =
      Node.self()
      |> Atom.to_string()
      |> String.split("@", parts: 2)
      |> hd()

    distributed_node_name == Atom.to_string(distribution_name())
  end

  defp distribution_name do
    suffix = Settings.get(:distribution_suffix, "")
    String.to_atom("voyager#{suffix}")
  end

  defp diagnose_failure(node_name) do
    case String.split(node_name, "@", parts: 2) do
      [name, host] -> diagnose_epmd_failure(name, host)
      _ -> {:error, :connection_failed}
    end
  end

  defp diagnose_epmd_failure(name, host) do
    task =
      Task.Supervisor.async_nolink(Voyager.TaskSupervisor, fn ->
        :erl_epmd.names(String.to_charlist(host))
      end)

    result = Task.yield(task, 1_000) || Task.shutdown(task)

    case result do
      {:ok, {:ok, registered}} -> diagnose_registered_name(name, host, registered)
      _ -> {:error, :connection_failed}
    end
  end

  defp diagnose_registered_name(name, host, registered) do
    name_cl = String.to_charlist(name)
    host_cl = String.to_charlist(host)

    case Enum.find(registered, fn {n, _port} -> n == name_cl end) do
      {_n, port} ->
        if port_alive?(host_cl, port) do
          diagnose_registered_failure(host)
        else
          {:error, :node_unreachable}
        end

      nil ->
        {:error, :connection_failed}
    end
  end

  defp port_alive?(host, port) do
    case :gen_tcp.connect(host, port, [], 1_000) do
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
      not longnames? and has_dots? -> {:error, :name_type_mismatch}
      longnames? and not has_dots? -> {:error, :name_type_mismatch}
      true -> {:error, :bad_cookie}
    end
  end
end
