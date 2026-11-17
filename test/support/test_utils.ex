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

  @doc """
  Empties a `Voyager.Settings.get_cached_choice/4` cache, so the next read loads
  it from the test's database, and restores it when the test exits.
  """
  def reset_cached_setting(cache_key) do
    previous = :persistent_term.get(cache_key, nil)
    :persistent_term.erase(cache_key)

    on_exit(fn ->
      if previous,
        do: :persistent_term.put(cache_key, previous),
        else: :persistent_term.erase(cache_key)
    end)
  end

  def reset_term_syntax(_context),
    do: reset_cached_setting({Voyager.Services.TermSyntax, :setting})

  def reset_pid_format(_context), do: reset_cached_setting({Voyager.Pid, :format})

  @doc """
  Polls `view` until `selector` renders, for results that reach the LiveView as plain
  messages `render_async/1` cannot await. Flunks after about a second.
  """
  def await_element(view, selector, text_filter \\ nil, attempts \\ 50)

  def await_element(_view, selector, _text_filter, 0),
    do: ExUnit.Assertions.flunk("timed out waiting for #{selector}")

  def await_element(view, selector, text_filter, attempts) do
    if Phoenix.LiveViewTest.has_element?(view, selector, text_filter) do
      :ok
    else
      receive do
      after
        20 -> :ok
      end

      await_element(view, selector, text_filter, attempts - 1)
    end
  end

  @doc "Evaluates `source` as one Erlang expression, the trailing dot added, and returns its value."
  def erl_eval(source) do
    {:ok, tokens, _end} = :erl_scan.string(String.to_charlist(source <> "."))
    {:ok, exprs} = :erl_parse.parse_exprs(tokens)
    {:value, value, _bindings} = :erl_eval.exprs(exprs, :erl_eval.new_bindings())
    value
  end
end
