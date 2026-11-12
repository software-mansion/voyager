defmodule VoyagerWeb.TermHighlight do
  @moduledoc """
  Splits an inspected term into syntax-kinded parts, each flagged when it matches a search
  query, for a component to render.
  """

  alias VoyagerWeb.TermTree.Segment

  @type part :: {Segment.kind() | nil, marked? :: boolean(), String.t()}

  @doc """
  The parts of `text`, in order; their concatenation is `text` again.

  A `nil` syntax skips the tokeniser and kinds every part `nil`. Marks are the
  ASCII-case-insensitive occurrences of `query`; a mark crossing a token's edge is split so
  each part keeps one kind. A `nil` or empty query marks nothing.
  """
  @spec parts(String.t(), :elixir | :erlang | nil, String.t() | nil) :: [part()]
  def parts(text, syntax, query \\ nil) do
    marks =
      if query in [nil, ""],
        do: [],
        else: :binary.matches(String.downcase(text, :ascii), String.downcase(query, :ascii))

    segments = if syntax, do: segments(text, syntax), else: [{nil, 0, byte_size(text)}]
    Enum.flat_map(segments, &segment_parts(text, &1, marks))
  end

  # A regex over the inspected text, since the row shows the formatter's output, not a term tree.
  defp segments(text, syntax) do
    kinds = kinds(syntax)

    {segments, from} =
      token_regex()
      |> Regex.scan(text, return: :index)
      |> Enum.flat_map_reduce(0, &match_segments(&1, &2, kinds))

    Enum.reject(segments ++ [{:punctuation, from, byte_size(text)}], fn {_kind, from, to} ->
      from == to
    end)
  end

  defp match_segments([{at, length} | groups], from, kinds) do
    case Enum.at(kinds, Enum.find_index(groups, fn {group_at, _length} -> group_at >= 0 end)) do
      nil -> {[], from}
      kind -> {[{:punctuation, from, at}, {kind, at, at + length}], at + length}
    end
  end

  # The last group is Erlang's bare and single-quoted atoms; Elixir leaves it as punctuation.
  defp kinds(:erlang), do: [:string, :other, :special, :atom, :number, :atom]
  defp kinds(_syntax), do: [:string, :other, :special, :atom, :number, nil]

  # A string may run to the end of the text, since rows cut long terms before the closing quote.
  defp token_regex,
    do:
      ~r/("(?:[^"\\]|\\.)*(?:"|$))|(~[a-zA-Z]+\[[^\]]*\]|#[A-Z][\w.]*<[^>]*>|<\d+\.\d+\.\d+>)|(\b(?:nil|true|false)\b)|(:"(?:[^"\\]|\\.)*"|:[a-zA-Z_][\w@]*[?!]?|\b[a-z_][\w@]*[?!]?:(?=\s)|\b[A-Z]\w*(?:\.[A-Z]\w*)*)|(-?\b\d[\d_]*(?:\.\d+)?(?:e[+-]?\d+)?\b)|('(?:[^'\\]|\\.)*'|\b[a-z][\w@]*)/

  # Marks arrive in order and never overlap, so their edges are already sorted.
  defp segment_parts(text, {kind, from, to}, marks) do
    edges =
      for {at, length} <- marks,
          edge <- [at, at + length],
          edge > from and edge < to,
          uniq: true,
          do: edge

    [from | edges]
    |> Enum.zip(edges ++ [to])
    |> Enum.map(fn {from, to} ->
      marked? = Enum.any?(marks, fn {at, length} -> from >= at and from < at + length end)
      {kind, marked?, binary_part(text, from, to - from)}
    end)
  end
end
