defmodule Voyager.TestUtils do
  @moduledoc """
  Shared test helpers.
  """

  import Ecto.Query, only: [from: 2]
  import ExUnit.Callbacks, only: [on_exit: 1]

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

  def enable_proxy_epmd(_context) do
    previous_epmd_module = :persistent_term.get(:voyager_epmd_module, :erl_epmd)
    :persistent_term.put(:voyager_epmd_module, Voyager.ProxyEpmd)
    on_exit(fn -> :persistent_term.put(:voyager_epmd_module, previous_epmd_module) end)
    :ok
  end

  def corrupt_secret!(%schema{id: id}, secret) do
    table = schema.__schema__(:source)
    Voyager.Repo.update_all(from(r in table, where: r.id == ^id), set: [{secret, "corrupt"}])
  end
end
