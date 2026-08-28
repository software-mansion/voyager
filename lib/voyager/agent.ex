defmodule Voyager.Agent do
  @moduledoc """
  Seam over `Voyager.Erpc` for calling the `:voyager_agent` module shipped to a
  remote node. Translates `:erpc` failures into `{:error, reason}` so no raw
  exception escapes to callers.
  """

  alias Voyager.Erpc

  @agent :voyager_agent

  @doc """
  Calls `:voyager_agent.fun(args...)` on `node`, bounded by `timeout`.

  Returns `{:ok, result}`, or `{:error, reason}` on failure.
  `{:error, {:remote_exception, :undef}}` usually means the agent is not loaded
  on the node yet.
  """
  @spec call(node(), atom(), [term()], timeout()) :: {:ok, term()} | {:error, Erpc.erpc_error()}
  def call(node, fun, args, timeout) do
    {:ok, Erpc.call(node, @agent, fun, args, timeout)}
  catch
    kind, reason -> Erpc.format_error(kind, reason)
  end
end
