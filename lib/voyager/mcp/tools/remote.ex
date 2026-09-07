defmodule Voyager.MCP.Tools.Remote do
  @moduledoc """
  Shared plumbing for the introspection tools: resolves the node held by
  `Voyager.NodeSession` and spends a `:high` priority
  `Voyager.Services.RateLimiter` token -- the tier manual GUI actions use.

  Payloads are sanitised before encoding: `Anubis.Server.Response.json/3` goes
  through `JSON.encode!/1`, which has no encoding for the pids, tuples, refs and
  arbitrary user terms process introspection returns.
  """

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Voyager.NodeSession
  alias Voyager.Services.RateLimiter

  @doc """
  Runs `fun` against the connected node and replies with its `{:ok, payload}` as
  JSON, or with a tool error for a missing session, a spent rate limit, or an
  `{:error, reason}`.
  """
  @spec reply((node() -> {:ok, term()} | {:error, term()}), Frame.t()) ::
          {:reply, Response.t(), Frame.t()}
  def reply(fun, frame) when is_function(fun, 1) do
    {:reply, run(fun), frame}
  end

  @doc """
  Parses the textual `"<X.Y.Z>"` form back into the pid it names, `nil` when
  malformed.

  The textual form carries the remote node's distribution channel index, so a
  pid printed from the connected node round-trips back to that node.
  """
  @spec parse_pid(String.t()) :: pid() | nil
  def parse_pid(pid_str) when is_binary(pid_str) do
    pid_str |> String.to_charlist() |> :erlang.list_to_pid()
  rescue
    ArgumentError -> nil
  end

  defp run(fun) do
    case NodeSession.current() do
      nil -> Response.error(Response.tool(), "Not connected to any node")
      session -> limited(session.node, fun)
    end
  end

  defp limited(node, fun) do
    case RateLimiter.run(:high, fn -> fun.(node) end) do
      {:ok, {:ok, payload}, _elapsed_us} ->
        Response.json(Response.tool(), jsonable(payload))

      {:ok, {:error, reason}, _elapsed_us} ->
        Response.error(Response.tool(), "fetch failed: #{inspect(reason)}")

      {:error, :rate_limited, retry_after_ms} ->
        Response.error(Response.tool(), "rate limited, retry in #{retry_after_ms}ms")
    end
  end

  defp jsonable(term) when is_atom(term) or is_number(term), do: term

  defp jsonable(term) when is_binary(term) do
    if String.valid?(term), do: term, else: inspect(term)
  end

  defp jsonable(term) when is_map(term) do
    Map.new(term, fn {key, value} -> {jsonable_key(key), jsonable(value)} end)
  end

  defp jsonable(term) when is_list(term) do
    if List.improper?(term), do: inspect(term), else: Enum.map(term, &jsonable/1)
  end

  defp jsonable(term) when is_tuple(term) do
    term |> Tuple.to_list() |> Enum.map(&jsonable/1)
  end

  defp jsonable(term), do: inspect(term)

  defp jsonable_key(key) when is_atom(key) or is_binary(key), do: key
  defp jsonable_key(key), do: inspect(key)
end
