defmodule Voyager.Services.Ets.MatchSpec do
  @moduledoc """
  Parses the source match spec `ets_search_table` sends, with `Voyager.MatchSpec`.

  The spec must be one `{head, guards, body}` clause, because the agent's `ets_select_spec/5`
  takes one, compile for a table, and fit the agent's size cap. It comes back encoded, so the
  search creates no atoms on the node; an atom the node lacks is `{:unknown_atom, name}` there.
  """

  alias Voyager.MatchSpec
  alias Voyager.MatchSpec.Refusals

  @type error :: {:invalid_match_spec, String.t()}

  @doc """
  Turns `"[{{'$1', active}, [], ['$1']}]"` into the encoded term the agent selects with.

  A missing trailing `.` is added.
  """
  @spec parse(String.t()) :: {:ok, term()} | {:error, error()}
  def parse(string) when is_binary(string) do
    with {:ok, spec} <- MatchSpec.parse(string),
         :ok <- MatchSpec.check_clauses(spec, 1),
         :ok <- MatchSpec.check_compiles(spec, :table),
         encoded = MatchSpec.encode(spec),
         :ok <- MatchSpec.check_size(encoded, Refusals.max_match_spec_bytes()) do
      {:ok, encoded}
    else
      {:error, :invalid_shape} -> invalid("expected a list of one {head, guards, body} clause")
      {:error, reason} -> invalid(MatchSpec.format_error(reason))
    end
  end

  defp invalid(detail), do: {:error, {:invalid_match_spec, detail}}
end
