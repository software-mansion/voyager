defmodule VoyagerWeb.TermTree.Node do
  @moduledoc """
  One level of a rendered term.

  A node knows how to draw itself both ways: `content` is the collapsed form
  (`%{...}`), while `expanded_before` and `expanded_after` wrap its children
  when it is open (`%{` … `}`). `truncated?` marks a container the remote node
  cut short, which is otherwise only visible once it is opened.

  Children are deliberately absent. `VoyagerWeb.TermTree.children/3` fetches
  them for the paths that are actually open, which is what keeps a collapsed
  branch free no matter how large the term behind it is.
  """

  alias VoyagerWeb.TermTree.Segment

  defstruct path: [],
            kind: :other,
            child_count: 0,
            truncated?: false,
            content: [],
            expanded_before: [],
            expanded_after: []

  @type kind ::
          :atom
          | :binary
          | :number
          | :tuple
          | :list
          | :map
          | :struct
          | :truncated
          | :other

  @type t :: %__MODULE__{
          path: [non_neg_integer()],
          kind: kind(),
          child_count: non_neg_integer(),
          truncated?: boolean(),
          content: [Segment.t()],
          expanded_before: [Segment.t()],
          expanded_after: [Segment.t()]
        }

  @spec expandable?(t()) :: boolean()
  def expandable?(%__MODULE__{child_count: child_count}), do: child_count > 0
end
