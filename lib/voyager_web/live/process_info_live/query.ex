defmodule VoyagerWeb.ProcessInfoLive.Query do
  @moduledoc """
  Loads everything the process info page shows, one function per section, each
  bounded by the caller's own `timeout`.

  Every load is user-triggered, so each spends one `:high` token from the rate
  limiter no matter how many remote calls it bundles. Limits live here because
  they are a property of what gets fetched, not of how it is rendered.
  """

  alias Voyager.Agent
  alias Voyager.Erpc
  alias Voyager.Services.ProcessInfo
  alias Voyager.Services.ProcessTerm
  alias Voyager.Services.RateLimiter

  @relations_limit 100
  @messages_limit 50
  @dictionary_limit 100

  @budget Agent.default_budget()

  @pid_format ~r/^<\d+\.\d+\.\d+>$/

  @type relations :: %{
          links: Agent.bounded(pid() | port()),
          monitors: Agent.bounded(ProcessInfo.monitor()),
          monitored_by: Agent.bounded(pid() | port())
        }

  @spec default_timeout() :: pos_integer()
  def default_timeout, do: Agent.default_timeout()

  @spec valid_pid_string?(String.t()) :: boolean()
  def valid_pid_string?(pid_string), do: Regex.match?(@pid_format, pid_string)

  @doc """
  Resolves a pid string on the remote node itself: a pid string names a
  process only on the node that prints it, so it cannot be parsed locally.
  """
  @spec resolve_pid(node(), String.t()) :: {:ok, pid()} | {:error, term()}
  def resolve_pid(node, pid_string) do
    Erpc.safe_call(node, :erlang, :list_to_pid, [String.to_charlist(pid_string)])
  end

  @spec overview(node(), pid(), timeout()) :: {:ok, map()} | {:error, term()}
  def overview(node, pid, timeout) do
    rate_limited(fn ->
      with {:ok, info} <- ProcessInfo.fetch(node, pid, timeout) do
        {:ok, Map.put(info, :label, label(node, pid, timeout))}
      end
    end)
  end

  @spec relations(node(), pid(), timeout()) :: {:ok, relations()} | {:error, term()}
  def relations(node, pid, timeout) do
    rate_limited(fn ->
      with {:ok, links} <- ProcessInfo.fetch_links(node, pid, @relations_limit, timeout),
           {:ok, monitors} <- ProcessInfo.fetch_monitors(node, pid, @relations_limit, timeout),
           {:ok, monitored_by} <-
             ProcessInfo.fetch_monitored_by(node, pid, @relations_limit, timeout) do
        {:ok, %{links: links, monitors: monitors, monitored_by: monitored_by}}
      end
    end)
  end

  @spec messages(node(), pid(), timeout()) ::
          {:ok, Agent.bounded(term())} | {:error, term()}
  def messages(node, pid, timeout) do
    rate_limited(fn ->
      ProcessTerm.fetch_messages(node, pid, @messages_limit, @budget, timeout)
    end)
  end

  @spec dictionary(node(), pid(), timeout()) ::
          {:ok, Agent.bounded(ProcessInfo.dictionary_entry())} | {:error, term()}
  def dictionary(node, pid, timeout) do
    rate_limited(fn ->
      ProcessInfo.fetch_dictionary(node, pid, @dictionary_limit, @budget, timeout)
    end)
  end

  @spec state(node(), pid(), timeout()) :: {:ok, Agent.truncated_term()} | {:error, term()}
  def state(node, pid, timeout) do
    rate_limited(fn -> ProcessTerm.fetch_state(node, pid, @budget, timeout) end)
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
