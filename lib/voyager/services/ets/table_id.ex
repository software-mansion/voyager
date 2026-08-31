defmodule Voyager.Services.Ets.TableId do
  @moduledoc """
  Identifies ETS tables across list fetches, `?table=` params, and MCP strings.

  A table handle is a **name atom** or a live **`reference()`** (unnamed tables).
  Display and matching use `inspect/1`. Unnamed tables cannot be rebuilt on the
  Voyager host — never `:erlang.list_to_ref/1` — so a reference inspect-string
  is resolved only against the last `:ets.all/0`. Typed names are interned on
  the *target* with `:erlang.list_to_existing_atom/1`, never `String.to_atom/1`
  on the host.
  """

  alias Voyager.Erpc

  @type t :: atom() | reference()

  @doc """
  Stable display form of a table handle, suitable for `?table=` and MCP.
  """
  @spec display(t()) :: String.t()
  def display(id) when is_atom(id) or is_reference(id), do: inspect(id)

  @doc """
  True when `string` is this handle's `inspect/1` form, or (for named tables)
  the atom's `Atom.to_string/1`.
  """
  @spec matches?(String.t(), t()) :: boolean()
  def matches?(string, id) when is_binary(string) and is_atom(id) do
    display(id) == string or Atom.to_string(id) == string
  end

  def matches?(string, id) when is_binary(string) and is_reference(id) do
    display(id) == string
  end

  @doc """
  Finds a handle in `ids` whose display form matches `string`.

  `ids` may be raw handles or `table_info` maps from
  `Voyager.Services.Ets.Remote` (matched on `:id`).
  """
  @spec find(String.t(), Enumerable.t()) :: {:ok, t()} | :error
  def find(string, ids) when is_binary(string) do
    Enum.find_value(ids, :error, fn item ->
      case unwrap(item) do
        nil -> false
        id -> matches?(string, id) && {:ok, id}
      end
    end)
  end

  @doc """
  Resolves `string` to a handle.

  Prefers a match against `ids` (the last `:ets.all/0`). Reference inspect
  strings that miss that list are **not** reconstructed. Remaining strings are
  interned on `node` via `:erlang.list_to_existing_atom/1`. A resolved name is
  not necessarily a live table — callers should still use `Remote.info/3`.
  """
  @spec resolve(node(), String.t(), Enumerable.t(), timeout()) ::
          {:ok, t()} | {:error, term()}
  def resolve(node, string, ids, timeout) when is_binary(string) do
    case find(string, ids) do
      {:ok, _} = ok ->
        ok

      :error ->
        if reference_inspect?(string) do
          {:error, :not_found}
        else
          existing_atom(node, string, timeout)
        end
    end
  end

  @doc """
  Interns `name` as an existing atom **on `node`**.

  A leading Elixir colon (`":foo"`) is stripped so inspect-forms of simple
  atoms can be typed without a prior `all`. Alias inspect-forms (`"MyApp.Cache"`)
  are interned as `:"Elixir.MyApp.Cache"`; a string that already starts with
  `"Elixir."` is left as-is. Returns `{:error, :not_found}` when the atom is
  not interned on the target.
  """
  @spec existing_atom(node(), String.t(), timeout()) :: {:ok, atom()} | {:error, term()}
  def existing_atom(node, name, timeout) when is_binary(name) do
    case atom_charlist(name) do
      :invalid ->
        {:error, :invalid_name}

      chars ->
        case Erpc.safe_call(node, :erlang, :list_to_existing_atom, [chars], timeout) do
          {:ok, atom} when is_atom(atom) -> {:ok, atom}
          {:ok, _} -> {:error, :invalid_response}
          {:error, {:remote_exception, :badarg}} -> {:error, :not_found}
          {:error, _} = err -> err
        end
    end
  end

  defp unwrap(%{id: id}) when is_atom(id) or is_reference(id), do: id
  defp unwrap(id) when is_atom(id) or is_reference(id), do: id
  defp unwrap(_), do: nil

  defp reference_inspect?(<<"#Ref", _::binary>>), do: true
  defp reference_inspect?(_), do: false

  defp atom_charlist(name) do
    case String.trim(name) do
      "" -> :invalid
      ":" -> :invalid
      ":" <> rest -> chars_or_invalid(rest)
      other -> chars_or_invalid(alias_name(other))
    end
  end

  defp alias_name(<<"Elixir.", _::binary>> = name), do: name
  defp alias_name(<<c, _::binary>> = name) when c in ?A..?Z, do: "Elixir." <> name
  defp alias_name(name), do: name

  defp chars_or_invalid(name) do
    case String.to_charlist(name) do
      [] -> :invalid
      chars -> chars
    end
  end
end
