defmodule Voyager.TestUtils do
  @moduledoc """
  Shared test helpers.
  """

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

  @doc """
  Sends `Voyager.Erpc` calls through the real transport until the test, or the
  module from `setup_all`, exits. The setting is VM-wide: `async: false` only.
  """
  def use_real_erpc(_context \\ %{}) do
    previous_erpc = Application.get_env(:voyager, :erpc)
    Application.put_env(:voyager, :erpc, :erpc)
    on_exit(fn -> Application.put_env(:voyager, :erpc, previous_erpc) end)
    :ok
  end
end
