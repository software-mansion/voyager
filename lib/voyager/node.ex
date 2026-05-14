defmodule Voyager.Node do
  @moduledoc """
  Represents a connection to a remote BEAM node.
  """

  defstruct [:name, :cookie, :status, :connected_at]

  @type status :: :connected | :disconnected | :connecting | :error

  @type t :: %__MODULE__{
          name: atom() | nil,
          cookie: atom() | nil,
          status: status(),
          connected_at: DateTime.t() | nil
        }
end
