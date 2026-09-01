defmodule Voyager.Services.Ets.TableId do
  @moduledoc """
  Identifies ETS tables as a name atom or a live `reference()`.

  Unnamed tables cannot be reconstructed from an inspect string
  (`:erlang.list_to_ref/1` is not used). Names are interned on the target with
  `:erlang.list_to_existing_atom/1`, never `String.to_atom/1` on the host.
  """

  alias Voyager.Erpc

  @max_atom_chars 255

  @type t :: atom() | reference()

  defguard is_table_id(id) when is_atom(id) or is_reference(id)

  @doc """
  `inspect/1` form of a table handle.
  """
  @spec display(t()) :: String.t()
  def display(id) when is_table_id(id), do: inspect(id)

  @doc """
  True when `string` matches `inspect/1`, or `Atom.to_string/1` for named tables.
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

  `ids` may be raw handles or `table_info` maps (matched on `:id`).
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

  Matches `ids` first. Reference inspect strings missing from that list are not
  reconstructed. Other strings are interned on `node`; a resolved name may not
  be a live table.
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
  Interns `name` as an existing atom on `node`.

  Strips a leading `:` so Elixir inspect-forms work. Alias inspect-forms
  (`"MyApp.Cache"`) are interned as `:"Elixir.MyApp.Cache"`. Returns
  `{:error, :not_found}` when the atom is not interned on the target.
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

  defp unwrap(%{id: id}) when is_table_id(id), do: id
  defp unwrap(id) when is_table_id(id), do: id
  defp unwrap(_), do: nil

  defp reference_inspect?(<<"#Ref", _::binary>>), do: true
  defp reference_inspect?(_), do: false

  defp atom_charlist(name) when byte_size(name) > @max_atom_chars * 4 + 8, do: :invalid

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

  defp chars_or_invalid(name) when byte_size(name) > @max_atom_chars * 4, do: :invalid

  defp chars_or_invalid(name) do
    case String.to_charlist(name) do
      [] -> :invalid
      chars when length(chars) > @max_atom_chars -> :invalid
      chars -> chars
    end
  end
end
