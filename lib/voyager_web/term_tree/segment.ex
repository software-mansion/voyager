defmodule VoyagerWeb.TermTree.Segment do
  @moduledoc """
  A fragment of rendered term text together with what that fragment is.

  A single line of a term is a run of differently coloured pieces — `name:` is
  an atom, the `" => "` after it is punctuation, `"voyager"` is a string — and
  each piece is one segment.

  Segments carry meaning, never styling. Turning a `:string` into a colour is
  the renderer's job, so the same tree can be drawn in a panel, a table cell or
  a test without the term logic knowing anything about CSS.
  """

  defstruct [:text, :kind]

  @type kind ::
          :atom
          | :number
          | :string
          | :special
          | :module
          | :punctuation
          | :muted
          | :other

  @type t :: %__MODULE__{text: String.t(), kind: kind()}
end
