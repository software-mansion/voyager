defmodule Voyager.Agent do
  @moduledoc """
  Seam for invoking the Voyager agent (`:voyager_agent`) that is shipped to and
  loaded on a remote node, over the `Voyager.Erpc` transport.

  Every call is wrapped so that `:erpc` failures surface as `{:error, reason}`
  tuples instead of raised exceptions — no raw exception escapes to callers.
  """

  alias Voyager.Erpc

  @agent :voyager_agent

  @doc """
  Invokes `fun` with `args` in the remote agent module on `node`, bounded by
  `timeout`.

  Returns `{:ok, result}` on success, or `{:error, reason}` on remote/transport
  failure (`:timeout`, `:noconnection`, `{:remote_exception, _}`,
  `{:remote_exit, _}`, `{:remote_throw, _}`, ...). An `{:error, {:remote_exception,
  :undef}}` typically means the agent has not been loaded on the node yet.
  """
  @spec call(node(), atom(), [term()], timeout()) :: {:ok, term()} | {:error, term()}
  def call(node, fun, args, timeout) do
    {:ok, Erpc.call(node, @agent, fun, args, timeout)}
  catch
    :error, {:erpc, :timeout} -> {:error, :timeout}
    :error, {:erpc, :noconnection} -> {:error, :noconnection}
    :error, {:exception, reason, _stack} -> {:error, {:remote_exception, reason}}
    :error, {:erpc, _} = reason -> {:error, reason}
    :error, reason -> {:error, reason}
    :exit, reason -> {:error, {:remote_exit, reason}}
    :throw, value -> {:error, {:remote_throw, value}}
  end
end
