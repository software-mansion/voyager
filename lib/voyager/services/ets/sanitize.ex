defmodule Voyager.Services.Ets.Sanitize do
  @moduledoc """
  Caps ETS record terms for host display. No redaction.

  Same numbers as the later Erlang truncator (VOY-230): 512-byte binaries,
  50 elements per collection, depth 5, then a `:"$voyager_truncated"` marker.
  Markers are leaves so a second pass (Fetch after an agent truncate) is
  idempotent.
  """

  @max_binary_bytes 512
  @max_collection 50
  @max_depth 5
  @marker :"$voyager_truncated"

  @type truncated ::
          {:"$voyager_truncated", :binary, binary(), non_neg_integer()}
          | {:"$voyager_truncated", :list, [term()], non_neg_integer()}
          | {:"$voyager_truncated", :map, map(), non_neg_integer()}
          | {:"$voyager_truncated", :tuple, [term()], non_neg_integer()}
          | {:"$voyager_truncated", :depth}

  @doc "Maximum kept prefix of an oversized binary, in bytes."
  @spec max_binary_bytes() :: 512
  def max_binary_bytes, do: @max_binary_bytes

  @doc "Maximum kept elements per list, map, or tuple."
  @spec max_collection() :: 50
  def max_collection, do: @max_collection

  @doc "Maximum nesting of lists, maps, and tuples before a depth marker."
  @spec max_depth() :: 5
  def max_depth, do: @max_depth

  @doc "Placeholder atom shared with the VOY-230 Erlang truncator."
  @spec marker() :: :"$voyager_truncated"
  def marker, do: @marker

  @doc """
  Returns a size-capped copy of `value`.

  Oversized binaries keep a 512-byte prefix. Collections keep 50 elements.
  Nesting stops at depth 5. Existing truncated markers are left unchanged.
  """
  @spec term(term()) :: term()
  def term(value), do: sanitize(value, 0)

  defp sanitize(term, depth) do
    cond do
      truncated?(term) -> term
      collection?(term) and depth >= @max_depth -> {@marker, :depth}
      true -> sanitize_value(term, depth)
    end
  end

  defp truncated?({@marker, :depth}), do: true
  defp truncated?({@marker, kind, _, _}) when kind in [:binary, :list, :map, :tuple], do: true
  defp truncated?(_), do: false

  defp collection?(term) when is_list(term) or is_map(term) or is_tuple(term), do: true
  defp collection?(_), do: false

  defp sanitize_value(bin, _depth) when is_binary(bin) do
    size = byte_size(bin)

    if size > @max_binary_bytes do
      {@marker, :binary, binary_part(bin, 0, @max_binary_bytes), size}
    else
      bin
    end
  end

  defp sanitize_value(bits, _depth) when is_bitstring(bits) do
    size = div(bit_size(bits) + 7, 8)
    {@marker, :binary, <<>>, size}
  end

  defp sanitize_value(list, depth) when is_list(list) do
    {taken, rest} = take_cons(list, @max_collection)
    sanitized = Enum.map(taken, &sanitize(&1, depth + 1))

    case rest do
      [] -> sanitized
      leftover -> {@marker, :list, sanitized, cons_count(leftover)}
    end
  end

  defp sanitize_value(%{} = map, depth) do
    pairs = map |> Map.to_list() |> Enum.sort()
    len = length(pairs)
    kept = Enum.take(pairs, @max_collection)

    taken =
      Map.new(kept, fn {key, value} ->
        {sanitize(key, depth + 1), sanitize(value, depth + 1)}
      end)

    if len > @max_collection do
      {@marker, :map, taken, len - @max_collection}
    else
      taken
    end
  end

  defp sanitize_value(tuple, depth) when is_tuple(tuple) do
    size = tuple_size(tuple)
    kept = tuple |> Tuple.to_list() |> Enum.take(@max_collection)
    sanitized = Enum.map(kept, &sanitize(&1, depth + 1))

    if size > @max_collection do
      {@marker, :tuple, sanitized, size - @max_collection}
    else
      List.to_tuple(sanitized)
    end
  end

  defp sanitize_value(term, _depth), do: term

  defp take_cons(list, n), do: take_cons(list, n, [])

  defp take_cons(list, n, acc) when n > 0 and is_list(list) and list != [] do
    [head | tail] = list
    take_cons(tail, n - 1, [head | acc])
  end

  defp take_cons(rest, _n, acc), do: {Enum.reverse(acc), rest}

  defp cons_count(list, acc \\ 0)
  defp cons_count([_head | tail], acc), do: cons_count(tail, acc + 1)
  defp cons_count([], acc), do: acc
  defp cons_count(_improper_tail, acc), do: acc + 1
end
