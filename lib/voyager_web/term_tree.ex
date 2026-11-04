defmodule VoyagerWeb.TermTree do
  @moduledoc """
  Turns a term into display nodes, one level at a time, in Elixir or Erlang
  syntax.

  Nothing is built up front: `describe/2` returns a single `Node` and
  `children/4` a windowed slice of its children, so a branch allocates nothing
  until it is opened, however large the term behind it is. Sizes are the
  exception — a list carries none, so counting one walks it, and the child
  totals and separators need that count. `State` records which paths are open,
  each path a list of child indexes from the root.

  Ordering has to be stable for those paths to mean anything between renders.
  Lists, tuples and keyword lists keep their own order — it is data. Map and
  struct keys have no meaningful order, so they are sorted, up to a size beyond
  which sorting on every render costs more than it is worth.

  Terms fetched from a remote node arrive already truncated, with elided
  subterms replaced in place by `#{inspect(:"$voyager_truncated")}` and cut
  binaries by `{#{inspect(:"$voyager_truncated")}, :binary, prefix, byte_size}`.
  Those render as a muted placeholder so a partial term is never mistaken for a
  complete one. See `priv/voyager_agent.erl` for the truncation itself.

  Every function taking `opts` picks how a term reads with `:syntax` (`:elixir`
  or `:erlang`), defaulting to `Voyager.Services.TermSyntax.current/0`.
  """

  alias Voyager.Services.TermSyntax
  alias VoyagerWeb.TermFormatter
  alias VoyagerWeb.TermFormatter.Erlang, as: ErlangFormatter
  alias VoyagerWeb.TermTree.Node
  alias VoyagerWeb.TermTree.Segment
  alias VoyagerWeb.TermTree.State

  @typedoc "A child as `children/4` returns it: its key segments, `nil` when positional, and its term."
  @type child :: {[Segment.t()] | nil, term()}

  @truncated :"$voyager_truncated"

  @window 50
  @sort_limit 200
  @auto_open_limit 5
  @auto_open_depth 5

  @inspect_opts [limit: 50, printable_limit: 4_096]
  @key_inspect_opts [limit: 5, printable_limit: 64]

  @doc """
  Builds the display node for `term`.

  Accepts `:path` (this node's position, for DOM ids and toggle events), `:key`
  (segments to prefix, as produced by `children/4`), `:comma?` (whether a
  separator follows this node in its parent) and `:syntax`.
  """
  @spec describe(term(), keyword()) :: Node.t()
  def describe(term, opts \\ []) do
    %Node{build(term, syntax(opts)) | path: Keyword.get(opts, :path, [])}
    |> prefix(Keyword.get(opts, :key))
    |> append_comma(Keyword.get(opts, :comma?, false))
  end

  @doc """
  Returns at most `limit` children of `term`, starting at `offset`.

  Each child is `{key_segments, child_term}`, where the segments render the key
  and its separator for maps, structs and keyword lists, and are `nil` for
  positional children.
  """
  @spec children(term(), non_neg_integer(), pos_integer(), keyword()) :: [child()]
  def children(term, offset, limit, opts \\ []) do
    children_of(term, offset, limit, syntax(opts))
  end

  @doc """
  The expansion state a term starts in: the root open, plus any short list or
  tuple below it, so small nested terms are readable without a click.

  Only branches that are opened are walked, and only to `:depth` levels, so the
  cost does not track the size of the term.
  """
  @spec initial_state(term(), keyword()) :: State.t()
  def initial_state(term, opts \\ []) do
    depth = Keyword.get(opts, :depth, @auto_open_depth)
    open_all? = Keyword.get(opts, :open_all, false)

    %State{open: MapSet.new([[] | auto_open(term, [], depth, open_all?, syntax(opts))])}
  end

  @spec open?(State.t(), State.path()) :: boolean()
  def open?(%State{open: open}, path), do: MapSet.member?(open, path)

  @spec toggle(State.t(), State.path()) :: State.t()
  def toggle(%State{open: open} = state, path) do
    open =
      if MapSet.member?(open, path) do
        MapSet.delete(open, path)
      else
        MapSet.put(open, path)
      end

    %State{state | open: open}
  end

  @doc "How many children of `path` are currently rendered."
  @spec window(State.t(), State.path()) :: pos_integer()
  def window(%State{windows: windows}, path), do: Map.get(windows, path, @window)

  @spec expand_window(State.t(), State.path()) :: State.t()
  def expand_window(%State{windows: windows} = state, path) do
    %State{state | windows: Map.update(windows, path, @window * 2, &(&1 + @window))}
  end

  @spec encode_path(State.path()) :: String.t()
  def encode_path(path), do: Enum.join(path, ".")

  @spec decode_path(term()) :: {:ok, State.path()} | :error
  def decode_path(""), do: {:ok, []}

  def decode_path(string) when is_binary(string) do
    path = string |> String.split(".") |> Enum.map(&String.to_integer/1)

    if Enum.all?(path, &(&1 >= 0)), do: {:ok, path}, else: :error
  rescue
    ArgumentError -> :error
  end

  def decode_path(_other), do: :error

  defp syntax(opts), do: Keyword.get_lazy(opts, :syntax, &TermSyntax.current/0)

  defp build(@truncated, _syntax) do
    %Node{kind: :truncated, content: [Segment.muted("… (truncated)")]}
  end

  defp build({@truncated, :binary, prefix, size}, syntax) do
    %Node{
      kind: :binary,
      content: build(prefix, syntax).content ++ [Segment.muted(" … (truncated, #{size} bytes)")]
    }
  end

  defp build(atom, syntax) when is_atom(atom) do
    %Node{kind: :atom, content: [atom_segment(atom, syntax)]}
  end

  defp build(binary, syntax) when is_binary(binary) do
    %Node{kind: :binary, content: [Segment.string(inspect_term(binary, syntax))]}
  end

  defp build(number, syntax) when is_number(number) do
    %Node{kind: :number, content: [Segment.number(inspect_term(number, syntax))]}
  end

  defp build({}, _syntax), do: %Node{kind: :tuple, content: [Segment.punctuation("{}")]}

  defp build(tuple, _syntax) when is_tuple(tuple) do
    branch(:tuple, tuple_size(tuple), @truncated in Tuple.to_list(tuple), "{", "}")
  end

  defp build([], _syntax), do: %Node{kind: :list, content: [Segment.punctuation("[]")]}

  defp build(list, syntax) when is_list(list) do
    with {:ok, count} <- list_length(list),
         false <- string_list?(list, syntax) do
      branch(:list, count, @truncated in list, "[", "]")
    else
      true -> %Node{kind: :list, content: [Segment.string(inspect_term(list, syntax))]}
      :improper -> build_other(list, syntax)
    end
  end

  defp build(%Regex{} = regex, :elixir), do: build_other(regex, :elixir)

  defp build(struct, :elixir) when is_struct(struct) do
    module_segments = [Segment.punctuation("%"), Segment.module(struct_name(struct))]

    content =
      if Inspect.impl_for(struct) == Inspect.Any do
        module_segments ++ [Segment.punctuation("{...}")]
      else
        [Segment.other(inspect_term(struct, :elixir))]
      end

    %Node{
      kind: :struct,
      child_count: struct |> Map.from_struct() |> map_size(),
      truncated?: elided_entry?(struct),
      content: content,
      expanded_before: module_segments ++ [Segment.punctuation("{")],
      expanded_after: [Segment.punctuation("}")]
    }
  end

  defp build(map, syntax) when map_size(map) == 0 do
    %Node{kind: :map, content: [Segment.punctuation(map_open(syntax) <> "}")]}
  end

  defp build(map, syntax) when is_map(map) do
    branch(:map, map_size(map), elided_entry?(map), map_open(syntax), "}")
  end

  defp build(other, syntax), do: build_other(other, syntax)

  defp branch(kind, count, truncated?, open, close) do
    %Node{
      kind: kind,
      child_count: count,
      truncated?: truncated?,
      content: [Segment.punctuation(open <> "..." <> close)],
      expanded_before: [Segment.punctuation(open)],
      expanded_after: [Segment.punctuation(close)]
    }
  end

  # The agent drops a fun or bignum that overruns the budget in place, so a
  # marker can sit anywhere in a container, not only where it was cut short.
  defp elided_entry?(map), do: Map.has_key?(map, @truncated) or @truncated in Map.values(map)

  defp build_other(term, syntax) do
    %Node{kind: :other, content: [Segment.other(inspect_term(term, syntax))]}
  end

  defp inspect_term(term, syntax),
    do: TermFormatter.inspect(term, [syntax: syntax] ++ @inspect_opts)

  defp atom_segment(atom, :elixir) when atom in [nil, true, false],
    do: Segment.special(inspect(atom))

  defp atom_segment(atom, :elixir) do
    text = inspect(atom)

    if String.starts_with?(text, ":") do
      Segment.atom(text)
    else
      Segment.module(text)
    end
  end

  defp atom_segment(atom, :erlang) when atom in [true, false, :undefined],
    do: Segment.special(ErlangFormatter.atom(atom))

  defp atom_segment(atom, :erlang), do: Segment.atom(ErlangFormatter.atom(atom))

  defp struct_name(%module{}) do
    case inspect(module) do
      ":" <> name -> name
      name -> name
    end
  end

  defp string_list?(list, syntax),
    do: TermFormatter.printable_list?(list, [syntax: syntax] ++ @inspect_opts)

  defp map_open(:elixir), do: "%{"
  defp map_open(:erlang), do: "\#{"

  defp children_of({@truncated, :binary, _prefix, _size}, _offset, _limit, _syntax), do: []

  defp children_of(tuple, offset, limit, _syntax) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> positional(offset, limit)
  end

  defp children_of(list, offset, limit, syntax) when is_list(list) do
    cond do
      list_length(list) == :improper or string_list?(list, syntax) ->
        []

      syntax == :elixir and list |> List.delete(@truncated) |> Inspect.List.keyword?() ->
        list |> Enum.slice(offset, limit) |> Enum.map(&keyword_pair/1)

      true ->
        positional(list, offset, limit)
    end
  end

  defp children_of(%Regex{}, _offset, _limit, :elixir), do: []

  defp children_of(struct, offset, limit, :elixir) when is_struct(struct) do
    struct |> Map.from_struct() |> children_of(offset, limit, :elixir)
  end

  defp children_of(map, offset, limit, syntax) when is_map(map) do
    {markers, rest} = pop_markers(map)
    pairs = ordered_pairs(rest)
    keyword? = syntax == :elixir and Enum.all?(pairs, &Inspect.List.keyword?([&1]))

    pairs
    |> Stream.concat(markers)
    |> Enum.slice(offset, limit)
    |> Enum.map(&key_value(&1, syntax, keyword?))
  end

  defp children_of(_term, _offset, _limit, _syntax), do: []

  defp positional(items, offset, limit) do
    items |> Enum.slice(offset, limit) |> Enum.map(&{nil, &1})
  end

  defp keyword_pair(@truncated), do: {nil, @truncated}

  defp keyword_pair({key, value}),
    do: {[Segment.atom(Macro.inspect_atom(:key, key)), Segment.punctuation(" ")], value}

  # A truncated subterm the agent left as a map key carries no information in
  # that position; rendering it as `key => value` would only repeat the marker.
  defp key_value({@truncated, _value}, _syntax, _keyword?), do: {nil, @truncated}
  defp key_value(pair, _syntax, true = _keyword?), do: keyword_pair(pair)

  defp key_value({key, value}, syntax, false = _keyword?),
    do: {key_content(key, syntax) ++ [Segment.punctuation(" => ")], value}

  defp key_content({@truncated, :binary, _prefix, _size} = key, syntax),
    do: build(key, syntax).content

  defp key_content(key, syntax) when is_tuple(key) or is_list(key) or is_map(key) do
    [Segment.other(TermFormatter.inspect(key, [syntax: syntax] ++ @key_inspect_opts))]
  end

  defp key_content(key, syntax), do: build(key, syntax).content

  defp list_length(list) do
    {:ok, length(list)}
  rescue
    ArgumentError -> :improper
  end

  defp prefix(node, nil), do: node

  defp prefix(%Node{} = node, segments) when is_list(segments) do
    %Node{
      node
      | content: segments ++ node.content,
        expanded_before: segments ++ node.expanded_before
    }
  end

  defp append_comma(node, false), do: node

  defp append_comma(%Node{} = node, true) do
    comma = [Segment.punctuation(",")]

    %Node{
      node
      | content: node.content ++ comma,
        expanded_after: node.expanded_after ++ comma
    }
  end

  defp pop_markers(map) do
    if Map.has_key?(map, @truncated) do
      {[{@truncated, Map.fetch!(map, @truncated)}], Map.delete(map, @truncated)}
    else
      {[], map}
    end
  end

  defp ordered_pairs(map) when map_size(map) > @sort_limit do
    Stream.unfold(:maps.iterator(map), fn iterator ->
      case :maps.next(iterator) do
        {key, value, rest} -> {{key, value}, rest}
        :none -> nil
      end
    end)
  end

  defp ordered_pairs(map), do: map |> Map.to_list() |> Enum.sort()

  defp auto_open(_term, _path, 0, _open_all?, _syntax), do: []

  defp auto_open(term, path, depth, open_all?, syntax) do
    term
    |> children_of(0, @window, syntax)
    |> Enum.with_index()
    |> Enum.flat_map(fn {{_key, child}, index} ->
      child_path = path ++ [index]

      if (open_all? and children_of(child, 0, 1, syntax) != []) or auto_open?(child, syntax) do
        [child_path | auto_open(child, child_path, depth - 1, open_all?, syntax)]
      else
        []
      end
    end)
  end

  defp auto_open?(term, syntax) do
    short?(term) and Node.expandable?(build(term, syntax))
  end

  defp short?(list) when is_list(list), do: short_list?(list, @auto_open_limit - 1)
  defp short?(tuple) when is_tuple(tuple), do: tuple_size(tuple) < @auto_open_limit
  defp short?(_term), do: false

  defp short_list?([], _max), do: true
  defp short_list?([_head | tail], max) when max > 0, do: short_list?(tail, max - 1)
  defp short_list?(_list, _max), do: false
end
