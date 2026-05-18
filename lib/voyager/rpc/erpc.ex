defmodule Voyager.RPC.ERPC do
  @moduledoc false

  @doc """
  Calls an MFA on a remote node, returning `{:ok, result} | {:error, reason}`.

  Normalizes all `:erpc` failure modes — `noconnection`, `timeout`, remote
  exceptions (wrapped as `{:erpc, {:exception, ...}}`) — into `{:error, term}`.
  """
  @spec call(atom(), module(), atom(), list(), timeout()) :: {:ok, term()} | {:error, term()}
  def call(node, mod, fun, args, timeout \\ 5_000) do
    {:ok, :erpc.call(node, mod, fun, args, timeout)}
  catch
    :error, {:erpc, reason} -> {:error, reason}
    :exit, reason -> {:error, {:exit, reason}}
    :throw, value -> {:error, {:throw, value}}
  end

  @doc """
  Like `call/5`, but returns the raw result on success or `nil` on any error.
  Useful for best-effort info fetching where a missing value is acceptable.
  """
  @spec fetch(atom(), module(), atom(), list(), timeout()) :: term()
  def fetch(node, mod, fun, args, timeout \\ 5_000) do
    case call(node, mod, fun, args, timeout) do
      {:ok, result} -> result
      {:error, _} -> nil
    end
  end
end
