defmodule Voyager.Services.ProcessTerm do
  @moduledoc """
  Fetches the unbounded terms held by a single process on a remote node: its
  `:sys` state and its mailbox.

  These are the expensive reads. Neither a rate limit nor a timeout bounds a
  *payload* -- a state or a mailbox can be gigabytes -- so both go through
  `:voyager_agent`, which rewrites the term on the remote to fit a `budget`
  before it crosses the distribution channel. Elided subterms come back as
  `:"$voyager_truncated"`; the reply's `:truncated?` says whether anything was
  dropped.

  Keep these explicit and user-triggered. They are never part of a default
  payload and never fetched on a refresh. A missing agent surfaces as
  `{:error, {:remote_exception, :undef}}`.
  """

  alias Voyager.Agent

  @timeout 5_000
  @budget 5_000

  # The remote's own `:sys.get_state/2` timeout has to fire before the `:erpc`
  # call gives up, or a slow process surfaces as an opaque transport timeout
  # instead of `{:error, :timeout}`.
  @erpc_margin 1_000

  @doc """
  Fetches the state of `pid` on `node`, truncated on the remote to at most
  `budget` visited terms.

  `timeout` bounds `:sys.get_state/2` on the remote. Returns `{:error, :dead}`
  for a process that is gone, `{:error, :timeout}` when it did not answer, and
  `{:error, :no_state}` when it rejected the request.

  A process that does not handle system messages at all -- a raw `spawn` -- is
  indistinguishable from a busy one: neither replies, so both are `:timeout`.
  """
  @spec fetch_state(node(), pid(), non_neg_integer(), timeout()) ::
          {:ok, Agent.truncated_term()} | {:error, term()}
  def fetch_state(node, pid, budget \\ @budget, timeout \\ @timeout)

  def fetch_state(node, pid, budget, timeout)
      when is_pid(pid) and is_integer(budget) and budget >= 0 do
    Agent.fetch(node, :proc_state, [pid, budget, timeout], timeout + @erpc_margin)
  end

  def fetch_state(_node, _pid, _budget, _timeout), do: {:error, :not_a_pid}

  @doc """
  Fetches the mailbox of `pid` on `node`, truncated on the remote to at most
  `limit` messages and `budget` visited terms.

  `:total` is the real mailbox length. Note that the remote has to copy the
  *whole* mailbox onto the agent's heap before truncating -- ERTS offers no
  capped mailbox read -- so the truncation bounds the payload, not the work. The
  agent's `max_heap_size` cap is what keeps a pathological mailbox from taking
  the remote node down.
  """
  @spec fetch_messages(node(), pid(), non_neg_integer(), non_neg_integer(), timeout()) ::
          {:ok, Agent.bounded(term())} | {:error, term()}
  def fetch_messages(node, pid, limit, budget \\ @budget, timeout \\ @timeout)

  def fetch_messages(node, pid, limit, budget, timeout)
      when is_pid(pid) and is_integer(limit) and limit >= 0 and is_integer(budget) and
             budget >= 0 do
    Agent.fetch(node, :proc_messages, [pid, limit, budget], timeout)
  end

  def fetch_messages(_node, _pid, _limit, _budget, _timeout), do: {:error, :not_a_pid}
end
