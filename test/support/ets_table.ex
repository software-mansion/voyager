defmodule Voyager.Test.EtsTable do
  @moduledoc """
  Unique ETS table names, so a `:named_table` cannot collide across tests.

  A table created in the test process dies with it — no cleanup callback needed.
  """

  @spec unique_name() :: atom()
  def unique_name, do: :"voyager_ets_#{System.unique_integer([:positive])}"
end
