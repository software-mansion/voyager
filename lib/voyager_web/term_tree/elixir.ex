defmodule VoyagerWeb.TermTree.Elixir do
  @moduledoc false
  @behaviour VoyagerWeb.TermTree

  alias VoyagerWeb.TermFormatter
  alias VoyagerWeb.TermTree
  alias VoyagerWeb.TermTree.Node
  alias VoyagerWeb.TermTree.Segment

  @truncated :"$voyager_truncated"

  @impl TermTree
  def build(atom) when is_atom(atom), do: %Node{kind: :atom, content: [atom_segment(atom)]}

  def build(%Regex{} = regex) do
    %Node{kind: :other, content: [Segment.other(TermTree.inspect_term(regex, :elixir))]}
  end

  def build(struct) when is_struct(struct) do
    module_segments = [Segment.punctuation("%"), Segment.module(struct_name(struct))]

    content =
      if Inspect.impl_for(struct) == Inspect.Any do
        module_segments ++ [Segment.punctuation("{...}")]
      else
        [Segment.other(TermTree.inspect_term(struct, :elixir))]
      end

    %Node{
      kind: :struct,
      child_count: struct |> Map.from_struct() |> map_size(),
      truncated?: Map.has_key?(struct, @truncated),
      content: content,
      expanded_before: module_segments ++ [Segment.punctuation("{")],
      expanded_after: [Segment.punctuation("}")]
    }
  end

  def build(term), do: TermTree.build_default(term, :elixir)

  @impl TermTree
  def children(list, offset, limit) when is_list(list) do
    if Keyword.keyword?(list) do
      list |> Enum.slice(offset, limit) |> TermTree.keyed(&key_segments/1)
    else
      TermTree.children_default(list, offset, limit, :elixir)
    end
  end

  def children(%Regex{}, _offset, _limit), do: []

  def children(struct, offset, limit) when is_struct(struct) do
    struct |> Map.from_struct() |> children(offset, limit)
  end

  def children(term, offset, limit), do: TermTree.children_default(term, offset, limit, :elixir)

  @impl TermTree
  def copy_string(term) do
    inspect(term,
      limit: :infinity,
      printable_limit: :infinity,
      pretty: true,
      structs: false,
      custom_options: [sort_maps: true],
      inspect_fun: &copy_inspect/2
    )
  end

  # Pids and other `#Name<...>` forms have no literal syntax. Rewriting the flattened output
  # instead would reach inside string literals and break any binary that reads like a pid.
  defp copy_inspect(id, _opts) when is_pid(id) or is_reference(id) or is_port(id) do
    {fun, text} = TermFormatter.identifier(id)
    ":erlang.#{fun}(#{inspect(String.to_charlist(text))})"
  end

  defp copy_inspect(fun, _opts) when is_function(fun) do
    case inspect(fun) do
      "#" <> _ = text -> inspect(text)
      text -> text
    end
  end

  defp copy_inspect(term, opts), do: Inspect.inspect(term, opts)

  defp atom_segment(atom) when atom in [nil, true, false], do: Segment.special(inspect(atom))

  defp atom_segment(atom) do
    text = inspect(atom)

    if String.starts_with?(text, ":") do
      Segment.atom(text)
    else
      Segment.module(text)
    end
  end

  @impl TermTree
  def key_segments(key) when is_atom(key) and key not in [nil, true, false] do
    case atom_segment(key) do
      %Segment{text: ":" <> name} = segment ->
        [%Segment{segment | text: name <> ":"}, Segment.punctuation(" ")]

      segment ->
        [segment, Segment.punctuation(" => ")]
    end
  end

  def key_segments(key), do: TermTree.key_content(key, :elixir) ++ [Segment.punctuation(" => ")]

  defp struct_name(%module{}) do
    case inspect(module) do
      ":" <> name -> name
      name -> name
    end
  end
end
