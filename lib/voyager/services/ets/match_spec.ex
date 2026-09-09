defmodule Voyager.Services.Ets.MatchSpec do
  @moduledoc """
  Parses a source match spec written as an Erlang term.

  The tool schema can only carry a string, so the spec arrives as text and is
  scanned and parsed with `:erl_parse.parse_term/1`. Only a literal term is
  accepted -- a call or a variable is a parse error -- and nothing is evaluated.

  Guard validity is not checked here: `:ets.select/3` on the target rejects a
  bad guard as `badarg`, which `Voyager.Services.Ets.Fetch` maps to
  `{:error, :cannot_read}`. Only the clause shape is, because
  `:voyager_agent.ets_select_spec/5` takes one `{head, guards, body}` clause.
  """

  @max_bytes 4_096

  @type spec :: [{term(), [term()], [term()]}]
  @type error :: {:invalid_match_spec, String.t()}

  @doc """
  Turns `"[{{'$1', active}, [], ['$1']}]"` into the term it spells.

  A missing trailing `.` is added.
  """
  @spec parse(String.t()) :: {:ok, spec()} | {:error, error()}
  def parse(string) when is_binary(string) and byte_size(string) > @max_bytes do
    invalid("longer than #{@max_bytes} bytes")
  end

  def parse(string) when is_binary(string) do
    with {:ok, term} <- parse_term(string) do
      validate(term)
    end
  end

  def parse(_string), do: invalid("not a string")

  # `:erl_scan` interns every atom in the string on this node, which is what the
  # byte cap above bounds.
  defp parse_term(string) do
    charlist = string |> terminate() |> String.to_charlist()

    with {:ok, tokens, _end} <- :erl_scan.string(charlist),
         {:ok, term} <- :erl_parse.parse_term(tokens) do
      {:ok, term}
    else
      {:error, reason, _end} -> invalid(format(reason))
      {:error, reason} -> invalid(format(reason))
    end
  end

  defp validate([{_head, guards, body}] = spec) when is_list(guards) and is_list(body) do
    {:ok, spec}
  end

  defp validate([_clause | _rest]), do: invalid("expected one {head, guards, body} clause")

  defp validate(_term), do: invalid("expected a list of one {head, guards, body} clause")

  defp terminate(string) do
    string |> String.trim_trailing() |> String.trim_trailing(".") |> Kernel.<>(".")
  end

  defp format({_location, module, description}) when is_atom(module) do
    description |> module.format_error() |> to_string()
  end

  defp format(reason), do: inspect(reason)

  defp invalid(detail), do: {:error, {:invalid_match_spec, detail}}
end
