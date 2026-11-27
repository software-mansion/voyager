defmodule Voyager.MatchSpec.ErlangParser do
  @moduledoc false

  alias Voyager.MatchSpec
  alias Voyager.MatchSpec.Utils

  @spec parse_term(String.t()) :: {:ok, term()} | {:error, MatchSpec.reason()}
  def parse_term(source) do
    with {:ok, tokens} <- scan(source),
         {:ok, exprs} <- parsed(:erl_parse.parse_exprs(tokens)),
         :ok <- Utils.check_segments(exprs) do
      parsed(:erl_parse.parse_term(tokens))
    end
  end

  @spec parse_fun(String.t(), :table | :trace) ::
          {:ok, MatchSpec.t()} | {:error, MatchSpec.reason()}
  def parse_fun(source, type) do
    with {:ok, tokens} <- scan(source),
         {:ok, exprs} <- parsed(:erl_parse.parse_exprs(tokens)) do
      case exprs do
        [{:fun, _anno, {:clauses, clauses}}] -> Utils.transform(clauses, type)
        _other -> {:error, {:syntax, "expected one fun ... end"}}
      end
    end
  end

  defp scan(source) do
    charlist = source |> terminate() |> String.to_charlist()

    case :erl_scan.string(charlist) do
      {:ok, tokens, _end} -> refuse_send(tokens)
      {:error, reason, _end} -> {:error, {:syntax, Utils.format_error_info(reason)}}
    end
  end

  # `:ms_transform` folds constant operators, so `init ! {stop, stop}` would really send.
  defp refuse_send(tokens) do
    if List.keymember?(tokens, :!, 0),
      do: {:error, {:syntax, "the ! operator is not allowed"}},
      else: {:ok, tokens}
  end

  defp parsed({:ok, term}), do: {:ok, term}
  defp parsed({:error, reason}), do: {:error, {:syntax, Utils.format_error_info(reason)}}

  defp terminate(source) do
    source |> String.trim_trailing() |> String.trim_trailing(".") |> Kernel.<>(".")
  end
end
