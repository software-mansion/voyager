defmodule Voyager.FuzzySearch do
  @moduledoc """
  Case-insensitive fuzzy matching of a query against a string, where the query's
  characters must appear in the string in order.
  """

  @typedoc "Lower is a better match: exact, prefix, substring, subsequence."
  @type rank :: 0..3

  @spec matches?(String.t(), String.t() | nil) :: boolean()
  def matches?(_string, query) when query in [nil, ""], do: true
  def matches?(string, query), do: subsequence?(String.downcase(string), String.downcase(query))

  @doc "Returns `nil` when `query` does not match `string` at all."
  @spec rank(String.t(), String.t()) :: rank() | nil
  def rank(string, query) do
    string = String.downcase(string)
    query = String.downcase(query)

    cond do
      string == query -> 0
      String.starts_with?(string, query) -> 1
      String.contains?(string, query) -> 2
      subsequence?(string, query) -> 3
      true -> nil
    end
  end

  defp subsequence?(_string, ""), do: true
  defp subsequence?("", _query), do: false

  defp subsequence?(<<c::utf8, string::binary>>, <<c::utf8, query::binary>>),
    do: subsequence?(string, query)

  defp subsequence?(<<_c::utf8, string::binary>>, query), do: subsequence?(string, query)
end
