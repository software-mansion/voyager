defmodule Voyager.Services.Ets.Sanitize do
  @moduledoc """
  Caps ETS record terms for host display. No redaction.

  Marker wrappers are preserved and payloads re-capped so a second pass is
  idempotent and a coincidental marker shape cannot smuggle an uncapped term.
  """

  @max_binary_bytes 512
  @max_collection 50
  @max_depth 5
  @marker :"$voyager_truncated"

  @type truncated ::
          {:"$voyager_truncated", :binary, binary(), non_neg_integer()}
          | {:"$voyager_truncated", :list, [term()], non_neg_integer()}
          | {:"$voyager_truncated", :map, [{term(), term()}], non_neg_integer()}
          | {:"$voyager_truncated", :tuple, [term()], non_neg_integer()}
          | {:"$voyager_truncated", :depth}

  @spec max_binary_bytes() :: 512
  def max_binary_bytes, do: @max_binary_bytes

  @spec max_collection() :: 50
  def max_collection, do: @max_collection

  @spec max_depth() :: 5
  def max_depth, do: @max_depth

  @spec marker() :: :"$voyager_truncated"
  def marker, do: @marker

  @spec term(term()) :: term()
  def term(value), do: sanitize(value, 0)

  defp sanitize({@marker, :depth}, _depth), do: {@marker, :depth}

  defp sanitize({@marker, kind, _payload, _meta}, depth)
       when kind in [:list, :map, :tuple] and depth >= @max_depth do
    {@marker, :depth}
  end

  defp sanitize({@marker, :binary, prefix, size}, _depth)
       when is_binary(prefix) and is_integer(size) and size >= 0 do
    {@marker, :binary, cap_binary(prefix), max(size, byte_size(prefix))}
  end

  defp sanitize({@marker, kind, elements, omitted}, depth)
       when kind in [:list, :map, :tuple] and is_list(elements) and is_integer(omitted) and
              omitted >= 0 do
    sanitize_collection_marker(kind, elements, omitted, depth)
  end

  defp sanitize([], depth) when depth >= @max_depth, do: []

  defp sanitize(%{} = map, depth) when map_size(map) == 0 and depth >= @max_depth, do: map

  defp sanitize({}, depth) when depth >= @max_depth, do: {}

  defp sanitize(term, depth)
       when (is_list(term) or is_map(term) or is_tuple(term)) and depth >= @max_depth do
    {@marker, :depth}
  end

  defp sanitize(term, depth), do: sanitize_value(term, depth)

  defp sanitize_value(bin, _depth) when is_binary(bin) do
    size = byte_size(bin)

    if size > @max_binary_bytes do
      {@marker, :binary, cap_binary(bin), size}
    else
      bin
    end
  end

  defp sanitize_value(bits, _depth) when is_bitstring(bits) and not is_binary(bits) do
    pad = 8 - rem(bit_size(bits), 8)
    padded = <<bits::bitstring, 0::size(pad)>>
    {@marker, :binary, cap_binary(padded), byte_size(padded)}
  end

  defp sanitize_value(list, depth) when is_list(list) do
    {taken, rest} = take_cons(list, @max_collection)
    sanitized = Enum.map(taken, &sanitize(&1, depth + 1))

    cond do
      rest == [] -> sanitized
      is_list(rest) -> {@marker, :list, sanitized, cons_count(rest)}
      true -> cons(sanitized, sanitize(rest, depth + 1))
    end
  end

  defp sanitize_value(%{} = map, depth) do
    pairs = map |> Map.to_list() |> Enum.sort()
    omitted = max(length(pairs) - @max_collection, 0)

    sanitized_pairs =
      pairs
      |> Enum.take(@max_collection)
      |> Enum.map(fn {key, value} ->
        {sanitize(key, depth + 1), sanitize(value, depth + 1)}
      end)

    rebuild_map(sanitized_pairs, omitted)
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

  defp sanitize_collection_marker(kind, elements, omitted, depth) do
    {taken, rest} = take_cons(elements, @max_collection)

    sanitized =
      case kind do
        :map -> Enum.map(taken, &sanitize_map_pair(&1, depth))
        _ -> Enum.map(taken, &sanitize(&1, depth + 1))
      end

    {@marker, kind, sanitized, omitted + leftover_count(rest)}
  end

  defp sanitize_map_pair({key, value}, depth) do
    {sanitize(key, depth + 1), sanitize(value, depth + 1)}
  end

  defp sanitize_map_pair(other, depth), do: sanitize(other, depth + 1)

  defp cap_binary(bin) when is_binary(bin) do
    kept =
      if byte_size(bin) > @max_binary_bytes do
        binary_part(bin, 0, @max_binary_bytes)
      else
        bin
      end

    :binary.copy(kept)
  end

  defp leftover_count(rest) when is_list(rest), do: cons_count(rest)
  defp leftover_count(_improper_tail), do: 1

  defp rebuild_map(pairs, 0) do
    as_map = Map.new(pairs)

    if map_size(as_map) == length(pairs) do
      as_map
    else
      {@marker, :map, pairs, 0}
    end
  end

  defp rebuild_map(pairs, omitted), do: {@marker, :map, pairs, omitted}

  defp cons(heads, tail) do
    Enum.reduce(Enum.reverse(heads), tail, fn head, acc -> [head | acc] end)
  end

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
