defmodule Voyager.Services.Ets.MatchSpec do
  @moduledoc """
  Parses the source match spec `ets_search_table` sends, with `Voyager.MatchSpec`.

  Guard validity is not checked here: `:ets.select/3` on the target rejects a
  bad guard as `badarg`, which `Voyager.Services.Ets.Fetch` maps to
  `{:error, :cannot_read}`. Only the clause shape is, because
  the agent's `ets_select_spec/5` takes one `{head, guards, body}` clause.
  """

  alias Voyager.MatchSpec

  @type error :: {:invalid_match_spec, String.t()}

  @doc """
  Turns `"[{{'$1', active}, [], ['$1']}]"` into the term it spells.

  A missing trailing `.` is added.
  """
  @spec parse(String.t()) :: {:ok, MatchSpec.t()} | {:error, error()}
  def parse(string) when is_binary(string) do
    with {:ok, spec} <- MatchSpec.parse(string),
         :ok <- MatchSpec.check_clauses(spec, 1) do
      {:ok, spec}
    else
      {:error, :invalid_shape} -> invalid("expected a list of one {head, guards, body} clause")
      {:error, reason} -> invalid(MatchSpec.format_error(reason))
    end
  end

  defp invalid(detail), do: {:error, {:invalid_match_spec, detail}}
end
