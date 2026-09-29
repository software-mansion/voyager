defmodule Voyager.Agent do
  @moduledoc """
  Seam over `Voyager.Erpc` for calling the agent module shipped to a remote
  node. Translates `:erpc` failures into `{:error, reason}` so no raw exception
  escapes to callers.

  The module is named after a digest of its own source (see `module/0`), so
  Voyagers running different agent code coexist on one node instead of
  reloading and purging each other's copy.
  """

  alias Voyager.Erpc
  alias Voyager.NodeSession
  alias Voyager.Services.CodeInjector

  @agent_source "voyager_agent.erl"
  @agent_prefix "voyager_agent_"
  @agent_digest_length 12
  @min_otp 27
  @otp_timeout 5_000
  @register_timeout 5_000
  @load_check_timeout 5_000

  @type install_error ::
          {:agent_install_failed,
           {:otp_too_old, String.t()}
           | {:otp_unknown, term()}
           | {:register_failed, term()}
           | CodeInjector.error_reason()}

  @default_timeout 5_000
  @default_budget 5_000

  @spec default_timeout() :: non_neg_integer()
  def default_timeout, do: @default_timeout

  @spec default_budget() :: non_neg_integer()
  def default_budget, do: @default_budget

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
  The remote module name for the agent source shipped with this build.

  `priv/voyager_agent.erl` declares `-module(?AGENT)`; the digest is passed as
  that macro at preprocess time, so the name and the code it stands for cannot
  drift apart. Cached because every remote call needs it, and re-derived by
  `install/1` so editing the source in dev does not ship the new code under the
  name the old code was loaded as.
  """
  @spec module() :: module()
  def module do
    case :persistent_term.get(__MODULE__, nil) do
      nil -> refresh_module()
      name -> name
    end
  end

  @doc "Minimum OTP release the agent requires on the remote node."
  @spec min_otp() :: pos_integer()
  def min_otp, do: @min_otp

  @doc """
  Loads the agent on `node` and registers this Voyager node with it.

  The remote OTP release is checked first.
  """
  @spec install(node()) :: :ok | {:error, install_error()}
  def install(node) do
    agent = refresh_module()

    with :ok <- check_otp(node),
         {:ok, ^agent} <- ensure_loaded(node, agent),
         {:ok, _pid} <- register(node) do
      :ok
    else
      {:error, reason} -> {:error, {:agent_install_failed, reason}}
    end
  end

  @doc """
  Calls `fun(args...)` on the remote agent, bounded by `timeout`.

  Returns `{:ok, result}`, or `{:error, reason}` on failure. An `:undef` from
  the remote means the agent is gone from an already-established connection, so
  the session is torn down.
  """
  @spec call(node(), atom(), [term()], timeout()) :: {:ok, term()} | {:error, Erpc.erpc_error()}
  def call(node, fun, args, timeout) do
    case Erpc.safe_call(node, module(), fun, args, timeout) do
      {:error, {:remote_exception, :undef}} = error ->
        NodeSession.agent_missing(node)
        error

      result ->
        result
    end
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

  defp refresh_module do
    name = derive_module()
    :persistent_term.put(__MODULE__, name)
    name
  end

  defp derive_module do
    digest =
      source_path()
      |> File.read!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, @agent_digest_length)

    String.to_atom(@agent_prefix <> digest)
  end

  defp source_path, do: Path.join(:code.priv_dir(:voyager), @agent_source)

  # The name is a digest of the source, so a loaded copy is already this code:
  # reloading would rotate it to old and purge an earlier Voyager's in-flight worker.
  defp ensure_loaded(node, agent) do
    case Erpc.safe_call(node, :code, :is_loaded, [agent], @load_check_timeout) do
      {:ok, false} -> CodeInjector.load(node, source_path(), AGENT: agent)
      {:ok, _loaded} -> {:ok, agent}
      {:error, _} = error -> error
    end
  end

  defp register(node) do
    case Erpc.safe_call(node, module(), :register, [Node.self()], @register_timeout) do
      {:ok, {:ok, pid}} -> {:ok, pid}
      {:ok, {:error, reason}} -> {:error, {:register_failed, reason}}
      {:ok, other} -> {:error, {:register_failed, other}}
      {:error, _} = error -> error
    end
  end

  defp check_otp(node) do
    with {:ok, release} <-
           Erpc.safe_call(node, :erlang, :system_info, [:otp_release], @otp_timeout),
         {:ok, version} <- parse_release(release) do
      if version >= @min_otp, do: :ok, else: {:error, {:otp_too_old, to_string(release)}}
    end
  end

  defp parse_release(release) when is_list(release) or is_binary(release) do
    case release |> to_string() |> Integer.parse() do
      {version, _rest} -> {:ok, version}
      :error -> {:error, {:otp_unknown, release}}
    end
  end

  defp parse_release(release), do: {:error, {:otp_unknown, release}}
end
