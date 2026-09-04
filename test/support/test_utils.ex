defmodule Voyager.TestUtils do
  @moduledoc """
  Shared test helpers.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @absent {__MODULE__, :absent}

  @doc """
  Converts changeset errors into a map of translated messages.
  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  @doc """
  Isolates a `:persistent_term` key for the current test.

  The previous value (or absence) is restored on exit. When `value` is given,
  it is written before the test runs so assertions do not depend on leftover
  state from other cases.
  """
  def isolate_persistent_term(key) do
    previous = fetch_persistent_term(key)
    on_exit(fn -> restore_persistent_term(key, previous) end)
    :ok
  end

  def isolate_persistent_term(key, value) do
    previous = fetch_persistent_term(key)
    :persistent_term.put(key, value)
    on_exit(fn -> restore_persistent_term(key, previous) end)
    :ok
  end

  defp fetch_persistent_term(key) do
    case :persistent_term.get(key, @absent) do
      @absent -> :absent
      value -> {:ok, value}
    end
  end

  defp restore_persistent_term(key, :absent), do: :persistent_term.erase(key)
  defp restore_persistent_term(key, {:ok, value}), do: :persistent_term.put(key, value)
end
