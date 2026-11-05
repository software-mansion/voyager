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
  each part keeps one kind. No query marks nothing.
  """
  @spec parts(String.t(), :elixir | :erlang | nil, String.t() | nil) :: [part()]
  def parts(text, syntax, query \\ nil) do
    marks =
      if query,
        do: :binary.matches(String.downcase(text, :ascii), String.downcase(query, :ascii)),
        else: []

    segments = if syntax, do: segments(text, syntax), else: [{nil, 0, byte_size(text)}]
    Enum.flat_map(segments, &segment_parts(text, &1, marks))
  end

  # A regex over the inspected text, since the row shows the formatter's output, not a term tree.
  defp segments(text, syntax) do
    kinds = [:string, :other, :special, :atom, :number]

    {segments, from} =
      syntax
      |> token_regex()
      |> Regex.scan(text, return: :index)
      |> Enum.flat_map_reduce(0, fn [{at, length} | groups], from ->
        kind =
          Enum.at(kinds, Enum.find_index(groups, fn {group_at, _length} -> group_at >= 0 end))

        {[{:punctuation, from, at}, {kind, at, at + length}], at + length}
      end)

    Enum.reject(segments ++ [{:punctuation, from, byte_size(text)}], fn {_kind, from, to} ->
      from == to
    end)
  end

  # Erlang terms spell atoms bare or in single quotes.
  defp token_regex(:erlang),
    do:
      ~r/("(?:[^"\\]|\\.)*")|(~[a-zA-Z]+\[[^\]]*\]|#[A-Z][\w.]*<[^>]*>|<\d+\.\d+\.\d+>)|(\b(?:nil|true|false)\b)|(:"(?:[^"\\]|\\.)*"|:[a-zA-Z_][\w@]*[?!]?|\b[a-z_][\w@]*[?!]?:(?=\s)|\b[A-Z]\w*(?:\.[A-Z]\w*)*|'(?:[^'\\]|\\.)*'|\b[a-z][\w@]*)|(-?\b\d[\d_]*(?:\.\d+)?(?:e[+-]?\d+)?\b)/

  defp token_regex(_syntax),
    do:
      ~r/("(?:[^"\\]|\\.)*")|(~[a-zA-Z]+\[[^\]]*\]|#[A-Z][\w.]*<[^>]*>|<\d+\.\d+\.\d+>)|(\b(?:nil|true|false)\b)|(:"(?:[^"\\]|\\.)*"|:[a-zA-Z_][\w@]*[?!]?|\b[a-z_][\w@]*[?!]?:(?=\s)|\b[A-Z]\w*(?:\.[A-Z]\w*)*)|(-?\b\d[\d_]*(?:\.\d+)?(?:e[+-]?\d+)?\b)/

  defp segment_parts(text, {kind, from, to}, marks) do
    edges =
      for {at, length} <- marks, edge <- [at, at + length], edge > from and edge < to, do: edge

    [from | Enum.sort(edges)]
    |> Enum.zip(Enum.sort(edges) ++ [to])
    |> Enum.map(fn {from, to} ->
      marked? = Enum.any?(marks, fn {at, length} -> from >= at and from < at + length end)
      {kind, marked?, binary_part(text, from, to - from)}
    end)
  end
end
