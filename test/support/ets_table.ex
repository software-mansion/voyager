defmodule Voyager.Test.EtsTable do
  @moduledoc """
  Unique ETS table names and delete-if-present cleanup for live tests.
  """

  @spec unique_name() :: atom()
  def unique_name, do: :"voyager_ets_#{System.unique_integer([:positive])}"

  @spec safe_delete(atom() | reference()) :: true | :ok
  def safe_delete(id) do
    :ets.delete(id)
  rescue
    ArgumentError -> :ok
  end
end
