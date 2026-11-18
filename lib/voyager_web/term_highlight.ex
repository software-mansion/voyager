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
    {parts, _marks} = Enum.flat_map_reduce(segments, marks, &segment_parts(text, &1, &2))
    parts
  end

  @doc """
  At most `length` graphemes of `parts`, starting `lead` graphemes ahead of the first mark
  when it lies further in, but never past the last `length`, so a text that fits stays whole
  and a cut one still shows its mark; `…` stands in for each cut end.
  """
  @spec clip([part()], non_neg_integer(), pos_integer()) :: [part()]
  def clip(parts, lead, length) do
    start = max(min(mark_offset(parts) - lead, text_length(parts) - length), 0)
    {_cut, parts} = split(parts, start)
    {shown, rest} = split(parts, length)
    ellipsis(start > 0) ++ shown ++ ellipsis(rest != [])
  end

  defp mark_offset(parts) do
    case Enum.split_while(parts, fn {_kind, marked?, _text} -> not marked? end) do
      {_unmarked, []} -> 0
      {unmarked, _from_mark} -> text_length(unmarked)
    end
  end

  defp text_length(parts), do: parts |> Enum.map(&String.length(elem(&1, 2))) |> Enum.sum()

  defp split(parts, 0), do: {[], parts}
  defp split([], _at), do: {[], []}

  defp split([{kind, marked?, text} = part | parts], at) do
    case String.length(text) do
      length when length <= at ->
        {head, tail} = split(parts, at - length)
        {[part | head], tail}

      _length ->
        {head, tail} = String.split_at(text, at)
        {[{kind, marked?, head}], [{kind, marked?, tail} | parts]}
    end
  end

  defp ellipsis(true), do: [{:punctuation, false, "…"}]
  defp ellipsis(false), do: []

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

  # A string may run to the end of the text, since tips cut long terms before the closing quote.
  defp token_regex,
    do:
      ~r/("(?:[^"\\]|\\.)*(?:"|$))|(~[a-zA-Z]+\[[^\]]*\]|#[A-Z][\w.]*<[^>]*>|<\d+\.\d+\.\d+>)|(\b(?:nil|true|false)\b)|(:"(?:[^"\\]|\\.)*"|:[a-zA-Z_][\w@]*[?!]?|\b[a-z_][\w@]*[?!]?:(?=\s)|\b[A-Z]\w*(?:\.[A-Z]\w*)*)|(-?\b\d[\d_]*(?:\.\d+)?(?:e[+-]?\d+)?\b)|('(?:[^'\\]|\\.)*'|\b[a-z][\w@]*)/

  # Segments tile the text in order and marks never overlap, so one walk splits them all.
  defp segment_parts(text, {kind, from, to}, marks) do
    {ranges, last} =
      marks
      |> Enum.take_while(fn {at, _length} -> at < to end)
      |> Enum.flat_map_reduce(from, fn {at, length}, at_least ->
        mark_end = min(at + length, to)
        {[{false, at_least, at}, {true, max(at, at_least), mark_end}], mark_end}
      end)

    parts =
      for {marked?, from, to} <- ranges ++ [{false, last, to}],
          from < to,
          do: {kind, marked?, binary_part(text, from, to - from)}

    {parts, Enum.drop_while(marks, fn {at, length} -> at + length <= to end)}
  end
end
