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
        false -> {:error, :connection_failed}
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
    if Node.alive?() and :net_kernel.longnames() != (name_type == :longnames) do
      :net_kernel.stop()
    end

    if Node.alive?() do
      :ok
    else
      case :net_kernel.start([@voyager_node_name, name_type]) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> {:error, {:net_kernel, reason}}
      end
    end
  end
end
