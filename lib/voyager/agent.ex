defmodule Voyager.Agent do
  @moduledoc """
  Seam over `Voyager.Erpc` for calling the `:voyager_agent` module shipped to a
  remote node. Translates `:erpc` failures into `{:error, reason}` so no raw
  exception escapes to callers.
  """

  alias Voyager.Erpc

  @agent :voyager_agent

  @typedoc """
  A remote-truncated view of an unbounded attribute. `:total` is the real length
  on the remote node, `:items` holds at most the requested limit, and
  `:truncated?` says whether anything was dropped -- either by the entry limit or
  by the term budget.
  """
  @type bounded(item) :: %{
          total: non_neg_integer(),
          truncated?: boolean(),
          items: [item]
        }

  @typedoc """
  A single arbitrary term rewritten on the remote to fit a term budget.
  `:truncated?` says whether anything was dropped; elided subterms are replaced
  by `:"$voyager_truncated"`.
  """
  @type truncated_term :: %{term: term(), truncated?: boolean()}

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

  @doc """
  Calls an agent function that replies with a truncated payload and flattens the
  result.

  The agent replies `{:ok, payload} | {:error, reason}` and `call/4` wraps that
  in its own `{:ok, _} | {:error, _}`; this collapses both layers and renames
  the payload's `:truncated` key to the `truncated?` boolean convention used on
  this side.
  """
  @spec fetch(node(), atom(), [term()], timeout()) ::
          {:ok, map()} | {:error, term()}
  def fetch(node, fun, args, timeout) do
    case call(node, fun, args, timeout) do
      {:ok, {:ok, %{truncated: truncated} = payload}} ->
        {:ok, payload |> Map.delete(:truncated) |> Map.put(:truncated?, truncated)}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, _} = err ->
        err
    end
  end
end
