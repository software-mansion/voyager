defmodule Voyager.MatchSpec.ErlangParser do
  @moduledoc false

  alias Voyager.MatchSpec

  # The agent's `TRACE_MAX_MATCH_SPEC_BYTES` (64 KiB): a bigger segment could never be sent.
  @max_segment_bits 524_288

  @spec parse_term(String.t()) :: {:ok, term()} | {:error, MatchSpec.reason()}
  def parse_term(source) do
    with {:ok, tokens} <- scan(source),
         {:ok, exprs} <- parsed(:erl_parse.parse_exprs(tokens)),
         :ok <- check_segments(exprs) do
      parsed(:erl_parse.parse_term(tokens))
    end
  end

  @spec parse_fun(String.t(), :table | :trace) ::
          {:ok, MatchSpec.t()} | {:error, MatchSpec.reason()}
  def parse_fun(source, type) do
    with {:ok, tokens} <- scan(source),
         {:ok, exprs} <- parsed(:erl_parse.parse_exprs(tokens)),
         :ok <- check_segments(exprs) do
      case exprs do
        [{:fun, _anno, {:clauses, clauses}}] -> transform(clauses, type)
        _other -> {:error, {:syntax, "expected one fun ... end"}}
      end
    end
  end

  defp scan(source) do
    charlist = source |> terminate() |> String.to_charlist()

    case :erl_scan.string(charlist) do
      {:ok, tokens, _end} -> refuse_send(tokens)
      {:error, reason, _end} -> {:error, {:syntax, format(reason)}}
    end
  end

  # `:ms_transform` folds constant operators, so `init ! {stop, stop}` would really send.
  defp refuse_send(tokens) do
    if List.keymember?(tokens, :!, 0),
      do: {:error, {:syntax, "the ! operator is not allowed"}},
      else: {:ok, tokens}
  end

  # One segment is one allocation, made before `max_heap_size` can stop the process.
  defp check_segments(exprs) do
    if oversized_segment?(exprs),
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

  defp parsed({:ok, term}), do: {:ok, term}
  defp parsed({:error, reason}), do: {:error, {:syntax, format(reason)}}

  defp transform(clauses, type) do
    dialect = if type == :trace, do: :dbg, else: :ets

    case :ms_transform.transform_from_shell(dialect, clauses, []) do
      {:error, [{_file, [reason | _]} | _], _warnings} -> {:error, {:unsupported, format(reason)}}
      spec -> {:ok, spec}
    end
  catch
    # `:ms_transform` raises on calls in a head (`fun({f(x)}) -> ok end`) and exits on crashes.
    _kind, _reason -> {:error, {:unsupported, "the fun cannot be turned into a match spec"}}
  end

  defp terminate(source) do
    source |> String.trim_trailing() |> String.trim_trailing(".") |> Kernel.<>(".")
  end

  defp format({_location, module, description}) when is_atom(module) do
    description |> module.format_error() |> to_string()
  end
end
