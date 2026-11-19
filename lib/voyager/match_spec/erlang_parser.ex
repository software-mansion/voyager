defmodule Voyager.MatchSpec.ErlangParser do
  @moduledoc false

  alias Voyager.MatchSpec

  @spec parse_term(String.t()) :: {:ok, term()} | {:error, MatchSpec.reason()}
  def parse_term(source) do
    with {:ok, tokens} <- scan(source) do
      parsed(:erl_parse.parse_term(tokens))
    end
  end

  @spec parse_fun(String.t(), :table | :trace) ::
          {:ok, MatchSpec.t()} | {:error, MatchSpec.reason()}
  def parse_fun(source, type) do
    with {:ok, tokens} <- scan(source),
         {:ok, exprs} <- parsed(:erl_parse.parse_exprs(tokens)) do
      case exprs do
        [{:fun, _anno, {:clauses, clauses}}] -> transform(clauses, type)
        _other -> {:error, {:syntax, "expected one fun ... end"}}
      end
    end
  end

  defp scan(source) do
    charlist = source |> terminate() |> String.to_charlist()

    case :erl_scan.string(charlist) do
      {:ok, tokens, _end} -> refuse_amplifiers(tokens)
      {:error, reason, _end} -> {:error, {:syntax, format(reason)}}
    end
  end

  # From a few bytes, `:erl_parse` builds `<<0:99999999999999>>` (gigabytes) and `:ms_transform`
  # folds `1 bsl 4000000` or `1 bsr -4000000` (0.5 MB each).
  defp refuse_amplifiers(tokens) do
    cond do
      List.keymember?(tokens, :":", 0) ->
        {:error, {:syntax, "calls and sized binary segments are not allowed"}}

      List.keymember?(tokens, :bsl, 0) or List.keymember?(tokens, :bsr, 0) ->
        {:error, {:syntax, "bsl and bsr are not allowed"}}

      true ->
        {:ok, tokens}
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
