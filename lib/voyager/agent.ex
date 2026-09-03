defmodule Voyager.Agent do
  @moduledoc """
  Seam over `Voyager.Erpc` for calling the `:voyager_agent` module shipped to a
  remote node. Translates `:erpc` failures into `{:error, reason}` so no raw
  exception escapes to callers.
  """

  alias Voyager.Erpc
  alias Voyager.NodeSession
  alias Voyager.Services.CodeInjector

  @agent :voyager_agent
  @agent_source "voyager_agent.erl"
  @min_otp 27
  @otp_timeout 5_000
  @register_timeout 5_000

  @type install_error ::
          {:agent_install_failed,
           {:otp_too_old, String.t()}
           | {:otp_unknown, term()}
           | {:register_failed, term()}
           | CodeInjector.error_reason()}

  @doc """
  Loads the agent on `node` and registers this Voyager node with it.

  The remote OTP release is checked first.
  """
  @spec install(node()) :: :ok | {:error, install_error()}
  def install(node) do
    path = Path.join(:code.priv_dir(:voyager), @agent_source)

    with :ok <- check_otp(node),
         {:ok, @agent} <- CodeInjector.load(node, path),
         {:ok, _pid} <- register(node) do
      :ok
    else
      {:error, reason} -> {:error, {:agent_install_failed, reason}}
    end
  end

  @doc """
  Calls `:voyager_agent.fun(args...)` on `node`, bounded by `timeout`.

  Returns `{:ok, result}`, or `{:error, reason}` on failure. An `:undef` from
  the remote means the agent is gone from an already-established connection, so
  the session is torn down.
  """
  @spec call(node(), atom(), [term()], timeout()) :: {:ok, term()} | {:error, Erpc.erpc_error()}
  def call(node, fun, args, timeout) do
    case Erpc.safe_call(node, @agent, fun, args, timeout) do
      {:error, {:remote_exception, :undef}} = error ->
        NodeSession.agent_missing(node)
        error

      result ->
        result
    end
  end

  defp register(node) do
    case Erpc.safe_call(node, @agent, :register, [Node.self()], @register_timeout) do
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
