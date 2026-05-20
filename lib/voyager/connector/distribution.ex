defmodule Voyager.Connector.Distribution do
  @moduledoc "Connects to remote nodes via Erlang distribution."

  @behaviour Voyager.Connector

  @voyager_node_name Application.compile_env(:voyager, :voyager_node_name, :voyager@localhost)

  @impl Voyager.Connector
  def connect(node_name, cookie, opts \\ []) do
    name_type = Keyword.get(opts, :name_type, :shortnames)

    with :ok <- ensure_distributed(name_type) do
      node = String.to_atom(node_name)
      :erlang.set_cookie(node, String.to_atom(cookie))

      case Node.connect(node) do
        true -> :ok
        false -> diagnose_failure(node_name)
        :ignored -> {:error, :not_distributed}
      end
    end
  end

  @impl Voyager.Connector
  def disconnect(node) do
    Node.disconnect(node)
    :ok
  end

  defp ensure_distributed(name_type) do
    cond do
      not Node.alive?() ->
        start_distribution(name_type)

      matches_name_type?(name_type) ->
        :ok

      true ->
        case :net_kernel.stop() do
          :ok -> start_distribution(name_type)
          {:error, reason} -> {:error, {:net_kernel_stop, reason}}
        end
    end
  end

  defp matches_name_type?(:longnames), do: :net_kernel.longnames() == true
  defp matches_name_type?(:shortnames), do: :net_kernel.longnames() == false

  defp start_distribution(name_type) do
    case :net_kernel.start(@voyager_node_name, %{name_domain: name_type, hidden: true}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, {:net_kernel, reason}}
    end
  end

  defp diagnose_failure(node_name) do
    case String.split(node_name, "@", parts: 2) do
      [name, host] ->
        task =
          Task.Supervisor.async_nolink(Voyager.TaskSupervisor, fn ->
            :erl_epmd.names(String.to_charlist(host))
          end)

        result = Task.yield(task, 1_000) || Task.shutdown(task)

        case result do
          {:ok, {:ok, registered}} ->
            name_cl = String.to_charlist(name)

            case Enum.find(registered, fn {n, _port} -> n == name_cl end) do
              {_n, port} ->
                if port_alive?(String.to_charlist(host), port) do
                  diagnose_registered_failure(host)
                else
                  {:error, :node_unreachable}
                end

              nil ->
                {:error, :connection_failed}
            end

          _ ->
            {:error, :connection_failed}
        end

      _ ->
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
