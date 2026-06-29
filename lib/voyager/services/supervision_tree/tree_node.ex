defmodule Voyager.Services.SupervisionTree.TreeNode do
  @moduledoc """
  A flat node representing a process, port or reference in a supervision tree.

  ## Node keys:

    * real-pid node → `"<X.Y.Z>"` (matches `:erlang.pid_to_list/1`)
    * `:app` wrapper → `"app:<app_atom>"`
    * port node → `inspect(port)`
    * reference node → `inspect(ref)`
    * ghost child (`pid: nil`) → `"<parent_key>::ghost::<inspect(child_id)>"`

  `name` is the process's display label: its `:registered_name` when
  registered, otherwise its pid. Ghost children (`pid: nil`) keep their
  supervisor child-spec id.

  `child_count` is the *direct* child count on the remote.
  """

  @derive Jason.Encoder
  @enforce_keys [:key, :type]
  defstruct [
    :key,
    :type,
    parent_key: nil,
    pid: nil,
    name: nil,
    child_count: 0,
    info: nil,
    children_keys: :not_loaded
  ]

  @type node_type :: :app | :supervisor | :worker | :port | :reference

  @type t :: %__MODULE__{
          key: String.t(),
          parent_key: String.t() | nil,
          pid: pid() | nil,
          # :name is mostly process's :registered_name if present or it's pid,
          # but if none present it default to child_id from supervision tree
          name: term(),
          type: node_type(),
          child_count: non_neg_integer(),
          info: map() | :dead | nil,
          children_keys: [String.t()] | :not_loaded
        }
end
