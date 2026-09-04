defmodule VoyagerWeb.TermTree do
  @moduledoc """
  Turns an Elixir term into display nodes, one level at a time.

  Nothing is built up front: `describe/2` returns a single `Node` and
  `children/3` a windowed slice of its children, so a collapsed branch costs
  nothing regardless of how large the term behind it is. `State` records which
  paths are open, each path a list of child indexes from the root.

  Ordering has to be stable for those paths to mean anything between renders.
  Lists, tuples and keyword lists keep their own order — it is data. Map and
  struct keys have no meaningful order, so they are sorted, up to a size beyond
  which sorting on every render costs more than it is worth.

  Terms fetched from a remote node arrive already truncated, with elided
  subterms replaced in place by `#{inspect(:"$voyager_truncated")}`. Those
  render as a muted placeholder so a partial term is never mistaken for a
  complete one. See `priv/voyager_agent.erl` for the truncation itself.
  """

  alias VoyagerWeb.TermTree.Node
  alias VoyagerWeb.TermTree.Segment
  alias VoyagerWeb.TermTree.State

  @truncated :"$voyager_truncated"

  @window 50
  @sort_limit 200
  @auto_open_limit 5
  @auto_open_depth 8

  @inspect_opts [limit: 50, printable_limit: 4_096]

  @doc """
  Builds the display node for `term`.

  Accepts `:path` (this node's position, for DOM ids and toggle events), `:key`
  (segments to prefix, as produced by `children/3`) and `:comma?` (whether a
  separator follows this node in its parent).
  """
  @spec describe(term(), keyword()) :: Node.t()
  def describe(term, opts \\ []) do
    node = %Node{build(term) | path: Keyword.get(opts, :path, [])}

    node
    |> prefix(Keyword.get(opts, :key))
    |> append_comma(Keyword.get(opts, :comma?, false))
  end

  @doc """
  Returns at most `limit` children of `term`, starting at `offset`.

  Each child is `{key_segments, child_term}`, where the segments render the key
  and its separator for maps, structs and keyword lists, and are `nil` for
  positional children.
  """
  @spec children(term(), non_neg_integer(), pos_integer()) :: [{[Segment.t()] | nil, term()}]
  def children(term, offset, limit)

  def children(tuple, offset, limit) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.slice(offset, limit)
    |> Enum.map(&{nil, &1})
  end

  def children(list, offset, limit) when is_list(list) do
    case list_length(list) do
      :improper ->
        []

      {:ok, _count} ->
        slice = Enum.slice(list, offset, limit)

        if Keyword.keyword?(list) do
          Enum.map(slice, &key_value/1)
        else
          Enum.map(slice, &{nil, &1})
        end
    end
  end

  def children(%Regex{}, _offset, _limit), do: []

  def children(struct, offset, limit) when is_struct(struct) do
    struct |> Map.from_struct() |> children(offset, limit)
  end

  def children(map, offset, limit) when is_map(map) do
    map
    |> Map.to_list()
    |> sorted_pairs()
    |> Enum.slice(offset, limit)
    |> Enum.map(&key_value/1)
  end

  def children(_term, _offset, _limit), do: []

  @doc """
  The expansion state a term starts in: the root open, plus any short list or
  tuple below it, so small nested terms are readable without a click.

  Only branches that are opened are walked, and only to `:depth` levels, so the
  cost does not track the size of the term.
  """
  @spec initial_state(term(), keyword()) :: State.t()
  def initial_state(term, opts \\ []) do
    depth = Keyword.get(opts, :depth, @auto_open_depth)

    %State{open: MapSet.new([[] | auto_open(term, [], depth)])}
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

  @spec decode_path(String.t()) :: {:ok, State.path()} | :error
  def decode_path(""), do: {:ok, []}

  def decode_path(string) when is_binary(string) do
    {:ok, string |> String.split(".") |> Enum.map(&String.to_integer/1)}
  rescue
    ArgumentError -> :error
  end

  @doc """
  Renders `term` as text that can be pasted back into IEx.

  Pids and other `#Name<...>` forms have no literal syntax, so they are
  rewritten into something that does round-trip.
  """
  @spec copy_string(term()) :: String.t()
  def copy_string(term) do
    inspect(term,
      limit: :infinity,
      printable_limit: :infinity,
      pretty: true,
      structs: false,
      inspect_fun: &copy_inspect/2
    )
  end

  # Rewriting the flattened output instead would reach inside string literals
  # and break the round-trip for any binary that happens to read like a pid.
  defp copy_inspect(pid, _opts) when is_pid(pid) do
    ":erlang.list_to_pid(~c\"" <> List.to_string(:erlang.pid_to_list(pid)) <> "\")"
  end

  defp copy_inspect(term, _opts)
       when is_reference(term) or is_port(term) or is_function(term) do
    case inspect(term) do
      "#" <> _ = text -> inspect(text)
      text -> text
    end
  end

  defp copy_inspect(term, opts), do: Inspect.inspect(term, opts)

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

  defp build(@truncated) do
    %Node{kind: :truncated, content: [Segment.muted("… (truncated)")]}
  end

  defp build(binary) when is_binary(binary) do
    %Node{kind: :binary, content: [Segment.string(inspect(binary, @inspect_opts))]}
  end

  defp build(atom) when is_atom(atom) do
    %Node{kind: :atom, content: [atom_segment(atom)]}
  end

  defp build(number) when is_number(number) do
    %Node{kind: :number, content: [Segment.number(inspect(number))]}
  end

  defp build({}) do
    %Node{kind: :tuple, content: [Segment.punctuation("{}")]}
  end

  defp build(tuple) when is_tuple(tuple) do
    %Node{
      kind: :tuple,
      child_count: tuple_size(tuple),
      content: [Segment.punctuation("{...}")],
      expanded_before: [Segment.punctuation("{")],
      expanded_after: [Segment.punctuation("}")]
    }
  end

  defp build([]) do
    %Node{kind: :list, content: [Segment.punctuation("[]")]}
  end

  defp build(list) when is_list(list) do
    with {:ok, count} <- list_length(list),
         false <- List.ascii_printable?(list) do
      %Node{
        kind: :list,
        child_count: count,
        content: [Segment.punctuation("[...]")],
        expanded_before: [Segment.punctuation("[")],
        expanded_after: [Segment.punctuation("]")]
      }
    else
      # A charlist reads as `~c"hi"` in IEx; showing it as a list of integers
      # would be honest but unrecognisable.
      true -> %Node{kind: :list, content: [Segment.string(inspect(list, @inspect_opts))]}
      :improper -> build_other(list)
    end
  end

  defp build(%Regex{} = regex) do
    %Node{kind: :other, content: [Segment.other(inspect(regex))]}
  end

  defp build(struct) when is_struct(struct) do
    module_segments = [Segment.punctuation("%"), Segment.module(struct_name(struct))]

    content =
      if Inspect.impl_for(struct) == Inspect.Any do
        module_segments ++ [Segment.punctuation("{...}")]
      else
        [Segment.other(inspect(struct, @inspect_opts))]
      end

    %Node{
      kind: :struct,
      child_count: struct |> Map.from_struct() |> map_size(),
      content: content,
      expanded_before: module_segments ++ [Segment.punctuation("{")],
      expanded_after: [Segment.punctuation("}")]
    }
  end

  defp build(map) when is_map(map) and map_size(map) == 0 do
    %Node{kind: :map, content: [Segment.punctuation("%{}")]}
  end

  defp build(map) when is_map(map) do
    %Node{
      kind: :map,
      child_count: map_size(map),
      content: [Segment.punctuation("%{...}")],
      expanded_before: [Segment.punctuation("%{")],
      expanded_after: [Segment.punctuation("}")]
    }
  end

  defp build(other), do: build_other(other)

  defp build_other(term) do
    %Node{kind: :other, content: [Segment.other(inspect(term, @inspect_opts))]}
  end

  defp atom_segment(atom) when atom in [nil, true, false], do: Segment.special(inspect(atom))

  defp atom_segment(atom) do
    text = inspect(atom)

    if String.starts_with?(text, ":") do
      Segment.atom(text)
    else
      Segment.module(text)
    end
  end

  # A truncated subterm the agent left as a map key carries no information in
  # that position; rendering it as `key => value` would only repeat the marker.
  defp key_value({@truncated, _value}), do: {nil, @truncated}
  defp key_value({key, value}), do: {key_segments(key), value}

  defp key_segments(key) when is_atom(key) and key not in [nil, true, false] do
    case atom_segment(key) do
      %Segment{text: ":" <> name} = segment ->
        [%Segment{segment | text: name <> ":"}, Segment.punctuation(" ")]

      segment ->
        [segment, Segment.punctuation(" => ")]
    end
  end

  defp key_segments(key) do
    describe(key).content ++ [Segment.punctuation(" => ")]
  end

  # The marker sorts by its own name, which would drop it in the middle of the
  # map; it means "and more", so it belongs at the end.
  defp sorted_pairs(pairs) do
    {markers, rest} = Enum.split_with(pairs, &match?({@truncated, _}, &1))

    if length(rest) > @sort_limit do
      rest ++ markers
    else
      Enum.sort(rest) ++ markers
    end
  end

  defp struct_name(%module{}) do
    case inspect(module) do
      ":" <> name -> name
      name -> name
    end
  end

  defp list_length(list) do
    {:ok, length(list)}
  rescue
    ArgumentError -> :improper
  end

  defp auto_open(_term, _path, 0), do: []

  defp auto_open(term, path, depth) do
    term
    |> children(0, @window)
    |> Enum.with_index()
    |> Enum.flat_map(fn {{_key, child}, index} ->
      child_path = path ++ [index]

      if auto_open?(child) do
        [child_path | auto_open(child, child_path, depth - 1)]
      else
        []
      end
    end)
  end

  defp auto_open?(list) when is_list(list) do
    case list_length(list) do
      {:ok, count} -> count > 0 and count < @auto_open_limit and not List.ascii_printable?(list)
      :improper -> false
    end
  end

  defp auto_open?(tuple) when is_tuple(tuple) do
    tuple_size(tuple) > 0 and tuple_size(tuple) < @auto_open_limit
  end

  defp auto_open?(_term), do: false
end
