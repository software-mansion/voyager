defmodule Voyager.MatchSpec.Utils do
  @moduledoc false

  alias Voyager.MatchSpec

  # The agent's `MAX_MATCH_SPEC_BYTES` (64 KiB): a bigger segment could never be sent.
  @max_segment_bits 524_288

  @doc """
  Refuses a binary segment in Erlang abstract format whose size is not an integer literal or
  whose size × unit is over 524288 bits. One segment is one allocation, made before
  `max_heap_size` can stop the process, so this runs before anything is built.
  """
  @spec check_segments(term()) :: :ok | {:error, MatchSpec.reason()}
  def check_segments(abstract) do
    if oversized_segment?(abstract),
      do:
        {:error,
         {:syntax,
          "binary segments must have an integer size of at most #{@max_segment_bits} bits"}},
      else: :ok
  end

  defp oversized_segment?({:bin_element, _anno, value, size, types}),
    do: not small_segment?(size, types) or oversized_segment?(value)

  defp oversized_segment?(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> oversized_segment?()

  defp oversized_segment?(list) when is_list(list), do: Enum.any?(list, &oversized_segment?/1)
  defp oversized_segment?(_term), do: false

  defp small_segment?(:default, _types), do: true

  defp small_segment?({kind, _anno, size}, types) when kind in [:integer, :char],
    do: size * unit(types) <= @max_segment_bits

  defp small_segment?(_size, _types), do: false

  defp unit(:default), do: 1

  defp unit(types) do
    case List.keyfind(types, :unit, 0) do
      {:unit, unit} -> unit
      nil -> if Enum.any?(types, &(&1 in [:binary, :bytes])), do: 8, else: 1
    end
  end
end
