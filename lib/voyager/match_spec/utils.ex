defmodule Voyager.MatchSpec.Utils do
  @moduledoc false

  alias Voyager.MatchSpec

  # A segment bigger than the agent's match spec cap could never be sent.
  @max_segment_bits Voyager.MatchSpec.Refusals.max_match_spec_bytes() * 8

  @doc "Turns a fun's clauses in Erlang abstract format into a match spec, as `fun2ms` does."
  @spec transform([tuple()], :table | :trace) ::
          {:ok, MatchSpec.t()} | {:error, MatchSpec.reason()}
  def transform(clauses, type) do
    with :ok <- check_segments(clauses), do: ms_transform(clauses, type)
  end

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

  @spec format_error_info({term(), module(), term()}) :: String.t()
  def format_error_info({_location, module, description}) when is_atom(module) do
    description |> module.format_error() |> to_string()
  end

  defp ms_transform(clauses, type) do
    dialect = if type == :trace, do: :dbg, else: :ets

    case :ms_transform.transform_from_shell(dialect, clauses, []) do
      {:error, [{_file, [reason | _]} | _], _warnings} ->
        {:error, {:unsupported, format_error_info(reason)}}

      spec ->
        {:ok, spec}
    end
  catch
    # `:ms_transform` raises on calls in a head (`fun({f(x)}) -> ok end`) and exits on crashes.
    _kind, _reason -> {:error, {:unsupported, "the fun cannot be turned into a match spec"}}
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
