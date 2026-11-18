defmodule Voyager.Services.Tracer.MatchSpec.ElixirParser do
  @moduledoc false

  @example "fn [a, _] when a > 10 -> true end"

  @operators %{
    ==: :==,
    !=: :"/=",
    ===: :"=:=",
    !==: :"=/=",
    <: :<,
    >: :>,
    <=: :"=<",
    >=: :>=,
    and: :andalso,
    or: :orelse,
    +: :+,
    -: :-,
    *: :*,
    /: :/,
    &&&: :band,
    |||: :bor,
    <<<: :bsl,
    >>>: :bsr
  }

  @special_forms :macros |> Kernel.SpecialForms.__info__() |> Keyword.keys() |> Enum.uniq()

  @spec parse(String.t()) :: {:ok, [tuple()]} | {:error, String.t()}
  def parse(source) do
    case Code.string_to_quoted(source, emit_warnings: false, columns: true) do
      {:ok, ast} -> {:ok, spec(ast)}
      {:error, {meta, message, token}} -> invalid!(error_message(message, token), meta)
    end
  catch
    {:invalid, message} -> {:error, message}
  end

  defp error_message({prefix, suffix}, token), do: "#{prefix}#{token}#{suffix}"
  defp error_message(message, token), do: "#{message}#{token}"

  defp spec({:fn, _meta, clauses}), do: Enum.flat_map(clauses, &clause/1)
  defp spec(_ast), do: invalid!("expected an fn such as `#{@example}`")

  defp clause({:->, meta, [[arg], body]}) do
    {arg, guards} = guards(arg, meta)
    {head, vars} = pattern(arg, %{})
    body = body(body, vars)

    case guards do
      [] -> [{head, [], body}]
      guards -> for guard <- guards, do: {head, [expr(guard, vars)], body}
    end
  end

  defp clause({:->, meta, _}), do: one_argument!(meta)

  defp guards({:when, _meta, [arg, guard]}, _clause_meta), do: {arg, alternatives(guard)}
  defp guards({:when, _meta, _args}, clause_meta), do: one_argument!(clause_meta)
  defp guards(arg, _clause_meta), do: {arg, []}

  defp alternatives({:when, _meta, [guard, rest]}), do: [guard | alternatives(rest)]
  defp alternatives(guard), do: [guard]

  defp one_argument!(meta),
    do: invalid!("an fn clause takes one argument, the list of call arguments", meta)

  defp body({:__block__, _meta, exprs}, vars), do: Enum.map(exprs, &expr(&1, vars))
  defp body(expr, vars), do: [expr(expr, vars)]

  defp pattern({name, meta, context}, vars) when is_atom(name) and is_atom(context) do
    if name in @special_forms, do: not_allowed!(name, meta)
    bind(name, vars)
  end

  defp pattern([{:|, _meta, [head, tail]}], vars) do
    {head, vars} = pattern(head, vars)
    {tail, vars} = pattern(tail, vars)
    {[head | tail], vars}
  end

  defp pattern([element | rest], vars) do
    {element, vars} = pattern(element, vars)
    {rest, vars} = pattern(rest, vars)
    {[element | rest], vars}
  end

  defp pattern([], vars), do: {[], vars}

  defp pattern({:++, meta, [prefix, rest]}, vars) do
    {prefix, vars} = pattern(prefix, vars)

    if not is_list(prefix) or List.improper?(prefix),
      do: invalid!("the left side of `++` must be a list", meta)

    {rest, vars} = pattern(rest, vars)
    {prefix ++ rest, vars}
  end

  defp pattern({left, right}, vars) do
    {elements, vars} = pattern([left, right], vars)
    {List.to_tuple(elements), vars}
  end

  defp pattern({:{}, _meta, elements}, vars) do
    {elements, vars} = pattern(elements, vars)
    {List.to_tuple(elements), vars}
  end

  defp pattern({:%{}, _meta, pairs}, vars) do
    {pairs, vars} = Enum.map_reduce(pairs, vars, &pattern_pair/2)
    {Map.new(pairs), vars}
  end

  defp pattern({:%, _meta, [module, {:%{}, _, _} = map]}, vars) do
    {map, vars} = pattern(map, vars)
    {Map.put(map, :__struct__, literal!(module)), vars}
  end

  defp pattern(ast, vars), do: {literal!(ast), vars}

  defp pattern_pair({key, value}, vars) do
    {value, vars} = pattern(value, vars)
    {{literal!(key), value}, vars}
  end

  defp pattern_pair(ast, _vars), do: unsupported!(ast)

  defp bind(name, vars) do
    cond do
      name == :_ ->
        {:_, vars}

      Map.has_key?(vars, name) ->
        {Map.fetch!(vars, name), vars}

      true ->
        var = :"$#{map_size(vars) + 1}"
        {var, Map.put(vars, name, var)}
    end
  end

  defp expr({name, meta, context}, vars) when is_atom(name) and is_atom(context) do
    case vars do
      %{^name => var} -> var
      _unbound -> invalid!("unknown variable #{name}", meta)
    end
  end

  defp expr({:__block__, _meta, [ast]}, vars), do: expr(ast, vars)
  defp expr({:in, meta, [left, right]}, vars), do: member(expr(left, vars), right, meta, vars)

  defp expr({operator, meta, _args}, _vars) when operator in [:&&, :||, :!],
    do: invalid!("`#{operator}` is not a guard, use `and`, `or` and `not`", meta)

  defp expr({operator, _meta, [left, right]}, vars) when is_map_key(@operators, operator),
    do: {Map.fetch!(@operators, operator), expr(left, vars), expr(right, vars)}

  defp expr({:-, _meta, [number]} = ast, _vars) when is_number(number), do: literal!(ast)
  defp expr({:__aliases__, _meta, _segments} = ast, _vars), do: literal!(ast)

  defp expr({sigil, _meta, _args} = ast, _vars) when sigil in [:sigil_c, :sigil_C],
    do: literal!(ast)

  defp expr({:{}, _meta, elements}, vars),
    do: {elements |> Enum.map(&expr(&1, vars)) |> List.to_tuple()}

  defp expr({:%{}, _meta, pairs}, vars), do: Map.new(pairs, &expr_pair(&1, vars))

  defp expr({:%, _meta, [module, {:%{}, _, _} = map]}, vars),
    do: map |> expr(vars) |> Map.put(:__struct__, literal!(module))

  defp expr({{:., meta, _target}, _call_meta, _args}, _vars),
    do: invalid!("remote calls are not allowed in a match spec", meta)

  defp expr({name, meta, args}, vars) when is_atom(name) and is_list(args),
    do: call(name, args, meta, vars)

  defp expr([{:|, _meta, [head, tail]}], vars), do: [expr(head, vars) | expr(tail, vars)]
  defp expr([head | tail], vars), do: [expr(head, vars) | expr(tail, vars)]
  defp expr([], _vars), do: []
  defp expr({left, right}, vars), do: {{expr(left, vars), expr(right, vars)}}
  defp expr(ast, _vars), do: literal!(ast)

  defp expr_pair({key, value}, vars), do: {literal!(key), expr(value, vars)}
  defp expr_pair(ast, _vars), do: unsupported!(ast)

  defp member(_term, [], _meta, _vars), do: false

  defp member(term, [_ | _] = list, meta, vars) do
    if List.improper?(list) or match?({:|, _, _}, List.last(list)),
      do: invalid!("`in` takes a literal list or a range", meta)

    list
    |> Enum.map(&{:"=:=", term, expr(&1, vars)})
    |> Enum.reduce(&{:orelse, &2, &1})
  end

  defp member(term, {:.., meta, [first, last]}, _in_meta, _vars) do
    {first, last} = {bound(first), bound(last)}

    if not (is_integer(first) and is_integer(last) and first <= last),
      do: invalid!("a range must run between two integers, lowest first", meta)

    {:andalso, {:is_integer, term}, {:andalso, {:>=, term, first}, {:"=<", term, last}}}
  end

  defp member(_term, _right, meta, _vars),
    do: invalid!("`in` takes a literal list or a range", meta)

  defp call(:is_nil, [term], _meta, vars), do: {:"=:=", expr(term, vars), nil}
  defp call(:"~~~", [term], _meta, vars), do: {:bnot, expr(term, vars)}

  defp call(:elem, [tuple, index], _meta, vars),
    do: {:element, element_index(index, vars), expr(tuple, vars)}

  defp call(:is_map_key, [map, key], _meta, vars),
    do: {:is_map_key, expr(key, vars), expr(map, vars)}

  defp call(:map_get, [map, key], _meta, vars), do: {:map_get, expr(key, vars), expr(map, vars)}

  defp call(:is_struct, [term], _meta, vars) do
    term = expr(term, vars)
    struct_test(term, {:is_atom, {:map_get, :__struct__, term}})
  end

  defp call(:is_struct, [term, module], meta, vars) do
    if not (is_atom(module) or match?({:__aliases__, _, _}, module)),
      do: invalid!("is_struct/2 takes a literal module name", meta)

    term = expr(term, vars)
    struct_test(term, {:"=:=", {:map_get, :__struct__, term}, literal!(module)})
  end

  defp call(name, args, meta, vars) do
    if name in @special_forms or name == :|, do: not_allowed!(name, meta)
    List.to_tuple([name | Enum.map(args, &expr(&1, vars))])
  end

  # `map_get/2` raises on a missing key, failing the guard even under `not`.
  defp struct_test(term, name_test) do
    {:andalso, {:is_map, term}, {:andalso, {:is_map_key, :__struct__, term}, name_test}}
  end

  defp bound({:-, _meta, [integer]}) when is_integer(integer), do: -integer
  defp bound(ast), do: ast

  # Elixir's `elem/2` counts from 0, the match spec's `element/2` from 1.
  defp element_index(index, _vars) when is_integer(index), do: index + 1
  defp element_index(index, vars), do: {:+, expr(index, vars), 1}

  defp literal!(atom) when is_atom(atom) do
    case Atom.to_string(atom) do
      "$" <> _ -> invalid!("#{inspect(atom)} is reserved in a match spec")
      "_" -> invalid!(":_ reads as a match spec wildcard, write `_` instead")
      _name -> atom
    end
  end

  defp literal!({:-, _meta, [number]}) when is_number(number), do: -number
  defp literal!(term) when is_number(term) or is_binary(term), do: term

  defp literal!({:__aliases__, meta, segments}) do
    if Enum.all?(segments, &is_atom/1),
      do: Module.concat(segments),
      else: invalid!("module names must be literal", meta)
  end

  defp literal!({:sigil_C, _meta, [{:<<>>, _, [string]}, []]}) when is_binary(string),
    do: String.to_charlist(string)

  defp literal!({:sigil_c, meta, [{:<<>>, _, [string]}, []]}) when is_binary(string) do
    string |> Macro.unescape_string() |> String.to_charlist()
  rescue
    _error in [ArgumentError, UnicodeConversionError] ->
      invalid!("invalid escape in the charlist", meta)
  end

  defp literal!(ast), do: unsupported!(ast)

  defp unsupported!({form, meta, _args}) when is_atom(form) and is_list(meta),
    do: not_allowed!(form, meta)

  defp unsupported!({_form, meta, _args}) when is_list(meta),
    do: invalid!("this expression is not allowed in a match spec", meta)

  defp unsupported!(_term), do: invalid!("a literal in the match spec is not allowed")

  defp not_allowed!(form, meta), do: invalid!("`#{form}` is not allowed in a match spec", meta)

  defp invalid!(message, meta) do
    case {meta[:line], meta[:column]} do
      {nil, _column} -> invalid!(message)
      {line, nil} -> invalid!("#{message} at line #{line}")
      {line, column} -> invalid!("#{message} at line #{line}, column #{column}")
    end
  end

  defp invalid!(message), do: throw({:invalid, message})
end
