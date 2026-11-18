defmodule Voyager.Services.Tracer.MatchSpec.ErlangParser do
  @moduledoc false

  @example "fun([A, _]) when A > 10 -> true end"

  @spec parse(String.t()) :: {:ok, [tuple()]} | {:error, String.t()}
  def parse(source) do
    with {:ok, tokens, _end} <- :erl_scan.string(terminate(source), {1, 1}),
         {:ok, [{:fun, _anno, {:clauses, clauses}}]} <- :erl_parse.parse_exprs(tokens),
         nil <- refused_form(clauses),
         spec when is_list(spec) <- transform(clauses) do
      {:ok, spec}
    else
      {:refused, message, location} ->
        {:error, message <> position(location)}

      :untranslatable ->
        {:error, "this fun cannot be translated into a match spec"}

      {:error, {location, module, description}, _end} ->
        located_error(location, module, description)

      {:error, {location, module, description}} ->
        located_error(location, module, description)

      {:error, [{_file, [{location, module, description} | _]} | _], _warnings} ->
        located_error(location, module, description)

      {:ok, _exprs} ->
        {:error, "expected a fun such as `#{@example}`"}
    end
  end

  defp terminate(source) do
    source
    |> String.trim_trailing()
    |> String.trim_trailing(".")
    |> Kernel.<>(".")
    |> String.to_charlist()
  end

  # ms_transform raises on forms it has no clause for, such as a call in the head.
  defp transform(clauses) do
    :ms_transform.transform_from_shell(:dbg, clauses, [])
  rescue
    _error -> :untranslatable
  catch
    _kind, _reason -> :untranslatable
  end

  # ms_transform reads '_' in a head as a wildcard, and builds a binary of any declared size here.
  defp refused_form({:atom, location, atom}) when is_atom(atom) do
    if atom == :_ or String.starts_with?(Atom.to_string(atom), "$"),
      do: {:refused, "the atom #{inspect(atom)} is reserved in a match spec", location}
  end

  defp refused_form({:bin_element, location, _value, size, type})
       when size != :default or type != :default,
       do: {:refused, "bit syntax sizes and types are not allowed in a match spec", location}

  defp refused_form(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> refused_form()
  defp refused_form([head | tail]), do: refused_form(head) || refused_form(tail)
  defp refused_form(_term), do: nil

  defp located_error(location, module, description) do
    message = description |> module.format_error() |> to_string()
    {:error, message <> position(location)}
  end

  defp position(location) do
    case {:erl_anno.line(location), :erl_anno.column(location)} do
      {:undefined, _column} -> ""
      {line, :undefined} -> " at line #{line}"
      {line, column} -> " at line #{line}, column #{column}"
    end
  end
end
