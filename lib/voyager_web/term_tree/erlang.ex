defmodule VoyagerWeb.TermTree.Erlang do
  @moduledoc false
  @behaviour VoyagerWeb.TermTree

  alias VoyagerWeb.TermFormatter.Erlang, as: ErlangFormatter
  alias VoyagerWeb.TermTree
  alias VoyagerWeb.TermTree.Node
  alias VoyagerWeb.TermTree.Segment

  @impl TermTree
  def build(atom) when is_atom(atom), do: %Node{kind: :atom, content: [atom_segment(atom)]}
  def build(term), do: TermTree.build_default(term, :erlang)

  @impl TermTree
  def children(term, offset, limit), do: TermTree.children_default(term, offset, limit, :erlang)

  @impl TermTree
  def copy_string(term), do: ErlangFormatter.inspect(term, pretty: true, round_trip: true)

  @impl TermTree
  def key_segments(key), do: TermTree.key_content(key, :erlang) ++ [Segment.punctuation(" => ")]

  defp atom_segment(atom) when atom in [true, false, :undefined],
    do: Segment.special(ErlangFormatter.atom(atom))

  defp atom_segment(atom), do: Segment.atom(ErlangFormatter.atom(atom))
end
