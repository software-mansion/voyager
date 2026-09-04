defmodule VoyagerWeb.TermTree.State do
  @moduledoc """
  Which parts of a rendered term are expanded.

  `open` holds the paths the user opened, each a list of child indexes from the
  root — `[0, 3]` is the fourth child of the first child. `windows` holds, per
  path, how many children of a long collection have been paged in so far;
  a path missing from it uses the default window.
  """

  defstruct open: MapSet.new(), windows: %{}

  @type path :: [non_neg_integer()]

  @type t :: %__MODULE__{
          open: MapSet.t(path()),
          windows: %{path() => pos_integer()}
        }
end
