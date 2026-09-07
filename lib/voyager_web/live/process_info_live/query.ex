defmodule VoyagerWeb.ProcessInfoLive.Query do
  @moduledoc """
  Loads everything the process info page shows, one function per section, each
  bounded by the caller's own `timeout` -- and, for the unbounded term fetches,
  the caller's own `budget`.

  Every load is user-triggered, so each spends one `:high` token from the rate
  limiter no matter how many remote calls it bundles. Limits live here because
  they are a property of what gets fetched, not of how it is rendered.
  """

  alias Voyager.Agent
  alias Voyager.Erpc
  alias Voyager.Services.ProcessInfo
  alias Voyager.Services.ProcessTerm
  alias Voyager.Services.RateLimiter

  @default_limits %{relations: 100, messages: 50, dictionary: 100}

  @budget Agent.default_budget()

  @pid_format ~r/^<\d+\.\d+\.\d+>$/

  @type relations :: %{
          links: Agent.bounded(pid() | port()),
          monitors: Agent.bounded(ProcessInfo.monitor()),
          monitored_by: Agent.bounded(pid() | port())
        }

  @spec default_timeout() :: pos_integer()
  def default_timeout, do: Agent.default_timeout()

  @spec default_budget() :: pos_integer()
  def default_budget, do: Agent.default_budget()

  @spec default_limits() :: %{atom() => pos_integer()}
  def default_limits, do: @default_limits

  @spec valid_pid_string?(String.t()) :: boolean()
  def valid_pid_string?(pid_string), do: Regex.match?(@pid_format, pid_string)

  @doc """
  Resolves a pid string to a pid of `node`. The normal form embeds this node's
  index for the owning node and parses locally; a `<0.X.Y>` string names a
  process only on the node that prints it, so it is resolved there.
  """
  @spec resolve_pid(node(), String.t()) :: {:ok, pid()} | {:error, term()}
  def resolve_pid(node, "<0." <> _rest = pid_string) do
    Erpc.safe_call(node, :erlang, :list_to_pid, [String.to_charlist(pid_string)])
  end

  def resolve_pid(node, pid_string) do
    pid = :erlang.list_to_pid(String.to_charlist(pid_string))
    if node(pid) == node, do: {:ok, pid}, else: {:error, :invalid_pid}
  rescue
    ArgumentError -> {:error, :invalid_pid}
  end

  @spec overview(node(), pid(), timeout()) :: {:ok, map()} | {:error, term()}
  def overview(node, pid, timeout) do
    rate_limited(fn ->
      with {:ok, info} <- ProcessInfo.fetch(node, pid, timeout) do
        {:ok, Map.put(info, :label, label(node, pid, timeout))}
      end
    end)
  end

  @spec relations(node(), pid(), non_neg_integer(), timeout()) ::
          {:ok, relations()} | {:error, term()}
  def relations(node, pid, limit, timeout) do
    rate_limited(fn ->
      with {:ok, links} <- ProcessInfo.fetch_links(node, pid, limit, timeout),
           {:ok, monitors} <- ProcessInfo.fetch_monitors(node, pid, limit, timeout),
           {:ok, monitored_by} <- ProcessInfo.fetch_monitored_by(node, pid, limit, timeout) do
        {:ok, %{links: links, monitors: monitors, monitored_by: monitored_by}}
      end
    end)
  end

  @spec messages(node(), pid(), non_neg_integer(), non_neg_integer(), timeout()) ::
          {:ok, Agent.bounded(term())} | {:error, term()}
  def messages(node, pid, limit, budget, timeout) do
    rate_limited(fn ->
      ProcessTerm.fetch_messages(node, pid, limit, budget, timeout)
    end)
  end

  @spec dictionary(node(), pid(), non_neg_integer(), non_neg_integer(), timeout()) ::
          {:ok, Agent.bounded(ProcessInfo.dictionary_entry())} | {:error, term()}
  def dictionary(node, pid, limit, budget, timeout) do
    rate_limited(fn ->
      ProcessInfo.fetch_dictionary(node, pid, limit, budget, timeout)
    end)
  end

  @spec state(node(), pid(), non_neg_integer(), timeout()) ::
          {:ok, Agent.truncated_term()} | {:error, term()}
  def state(node, pid, budget, timeout) do
    rate_limited(fn -> ProcessTerm.fetch_state(node, pid, budget, timeout) end)
  end

  # A label is an arbitrary term needing the agent's remote truncation; a node
  # without the agent simply has no label to show -- it must not fail the
  # overview.
  defp label(node, pid, timeout) do
    case ProcessInfo.fetch_label(node, pid, @budget, timeout) do
      {:ok, %{term: term}} -> term
      {:error, _reason} -> nil
    end
  end

  defp rate_limited(fun) do
    case RateLimiter.run(:high, fun) do
      {:ok, result, _elapsed_us} -> result
      {:error, :rate_limited, _retry_after_ms} -> {:error, :rate_limited}
    end
  end
end
