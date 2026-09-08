defmodule Voyager.MCP.Tools.Remote do
  @moduledoc false

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Voyager.NodeSession
  alias Voyager.Services.RateLimiter

  @spec reply((node() -> {:ok, term()} | {:error, term()}), Frame.t()) ::
          {:reply, Response.t(), Frame.t()}
  def reply(fun, frame) when is_function(fun, 1) do
    {:reply, run(fun), frame}
  end

  defp run(fun) do
    case NodeSession.current() do
      nil -> Response.error(Response.tool(), "Not connected to any node")
      session -> limited(session.node, fun)
    end
  end

  defp limited(node, fun) do
    case RateLimiter.run(rate_limiter(), :high, fn -> fun.(node) end) do
      {:ok, {:ok, payload}, _elapsed_us} ->
        Response.json(Response.tool(), jsonable(payload))

      {:ok, {:error, reason}, _elapsed_us} ->
        Response.error(Response.tool(), "fetch failed: #{inspect(reason)}")

      {:error, :rate_limited, retry_after_ms} ->
        Response.error(Response.tool(), "rate limited, retry in #{retry_after_ms}ms")
    end
  end

  defp rate_limiter, do: Application.get_env(:voyager, :rate_limiter, RateLimiter)

  # Only the terms `Voyager.JSONEncoders` cannot reach: lists, binaries and map
  # keys are resolved before protocol dispatch, and a struct defined on the
  # remote node has no implementation to find.
  defp jsonable(term) when is_binary(term) do
    if String.valid?(term), do: term, else: inspect(term)
  end

  defp jsonable(%module{} = term) do
    if JSON.Encoder.impl_for(term) do
      term
    else
      term
      |> Map.from_struct()
      |> jsonable()
      |> Map.put(:__struct__, inspect(module))
    end
  end

  defp jsonable(term) when is_map(term) do
    Map.new(term, fn {key, value} -> {jsonable_key(key), jsonable(value)} end)
  end

  defp jsonable(term) when is_list(term) do
    cond do
      List.improper?(term) -> inspect(term)
      printable_charlist?(term) -> List.to_string(term)
      true -> Enum.map(term, &jsonable/1)
    end
  end

  defp jsonable(term) when is_tuple(term) do
    term |> Tuple.to_list() |> Enum.map(&jsonable/1) |> List.to_tuple()
  end

  defp jsonable(term), do: term

  # An empty list is ascii-printable, and rendering `[]` as `""` would be worse
  # than the integer array this clause exists to avoid.
  defp printable_charlist?([]), do: false
  defp printable_charlist?(term), do: List.ascii_printable?(term)

  defp jsonable_key(key) when is_atom(key), do: key
  defp jsonable_key(key) when is_binary(key), do: jsonable(key)
  defp jsonable_key(key), do: inspect(key)
end
