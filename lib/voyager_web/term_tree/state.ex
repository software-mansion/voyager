defmodule VoyagerWeb.TermTree.State do
  @moduledoc """
  Which parts of a rendered term are expanded.

  `open` holds the paths the user opened, each a list of child indexes from the
  root — `[0, 3]` is the fourth child of the first child. `windows` holds, per
  path, how many children of a long collection have been paged in so far;
  a path missing from it uses the default window. `syntax` pins the term syntax
  the paths were computed in, so a setting change cannot shift them; `nil`
  follows the current setting.
  """

  defstruct open: MapSet.new(), windows: %{}, syntax: nil

  @type path :: [non_neg_integer()]

  @type t :: %__MODULE__{
          open: MapSet.t(path()),
          windows: %{path() => pos_integer()},
          syntax: Voyager.Services.TermSyntax.syntax() | nil
        }
end
