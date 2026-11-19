defmodule Voyager.MatchSpec.ElixirParser do
  @moduledoc false

  alias Voyager.MatchSpec

  @comparisons %{
    ==: :==,
    !=: :"/=",
    ===: :"=:=",
    !==: :"=/=",
    <: :<,
    >: :>,
    <=: :"=<",
    >=: :>=
  }
  @booleans %{and: :andalso, or: :orelse}
  @special_forms ~w(__MODULE__ __DIR__ __ENV__ __CALLER__ __STACKTRACE__)a
  @type_checks ~w(is_atom is_binary is_bitstring is_boolean is_float is_function is_integer
                  is_list is_map is_number is_pid is_port is_reference is_tuple)a

  @spec parse_fun(String.t(), :table | :trace) ::
          {:ok, MatchSpec.t()} | {:error, MatchSpec.reason()}
  def parse_fun(source, type) do
    case Code.string_to_quoted(source, emit_warnings: false) do
      {:ok, {:fn, _meta, clauses}} -> translate(clauses, type)
      {:ok, _other} -> {:error, {:syntax, "expected one fn ... end"}}
      {:error, {_location, message, token}} -> {:error, {:syntax, syntax_message(message, token)}}
    end
  end

  defp translate(clauses, type) do
    {:ok, Enum.flat_map(clauses, &clause(&1, type))}
  catch
    {:unsupported, message} -> {:error, {:unsupported, message}}
  end

  # Each `when` of a clause is a guard alternative, as `;` is in Erlang, so it gets its own clause.
  defp clause({:->, _meta, [[{:when, _when_meta, [param, guard]}], body]}, type) do
    {head, vars} = head(param, type)
    body = body(body, vars)
    for alternative <- alternatives(guard), do: {head, [expr(alternative, vars)], body}
  end

  defp clause({:->, _meta, [[{:when, _when_meta, args}], _body]}, _type),
    do: one_parameter!(length(args) - 1)

  defp clause({:->, _meta, [[param], body]}, type) do
    {head, vars} = head(param, type)
    [{head, [], body(body, vars)}]
  end

  defp clause({:->, _meta, [params, _body]}, _type), do: one_parameter!(length(params))

  defp one_parameter!(count), do: unsupported!("expected one parameter, got #{count}")

  defp alternatives({:when, _meta, [guard, rest]}), do: [guard | alternatives(rest)]
  defp alternatives(guard), do: [guard]

  defp head(param, type) do
    if variable_ast?(param) or shape_ast?(param, type) do
      pattern(param, %{})
    else
      unsupported!(head_message(type))
    end
  end

  defp shape_ast?(param, :trace), do: is_list(param)
  defp shape_ast?({:{}, _meta, _elements}, :table), do: true
  defp shape_ast?({_left, _right}, :table), do: true
  defp shape_ast?(_param, :table), do: false

  defp head_message(:trace),
    do: "the parameter must be a variable or a list of the call's arguments"

  defp head_message(:table), do: "the parameter must be a variable or a tuple matching the row"

  defp body({:__block__, _meta, exprs}, vars), do: Enum.map(exprs, &expr(&1, vars))
  defp body(expr, vars), do: [expr(expr, vars)]

  defp pattern({name, _meta, context} = ast, vars) when is_atom(name) and is_atom(context) do
    cond do
      name == :_ -> {:_, vars}
      name in @special_forms -> unsupported_ast!(ast)
      Map.has_key?(vars, name) -> {vars[name], vars}
      true -> bind(ast, vars)
    end
  end

  defp pattern(list, vars) when is_list(list), do: list_of(list, vars, &pattern/2)

  defp pattern({:{}, _meta, elements}, vars) do
    {elements, vars} = Enum.map_reduce(elements, vars, &pattern/2)
    {List.to_tuple(elements), vars}
  end

  defp pattern({:%{}, _meta, pairs}, vars) do
    {pairs, vars} =
      Enum.map_reduce(pairs, vars, fn
        {key, value}, vars ->
          {value, vars} = pattern(value, vars)
          {{literal(key), value}, vars}

        other, _vars ->
          unsupported_ast!(other)
      end)

    {Map.new(pairs), vars}
  end

  defp pattern({left, right}, vars) do
    {[left, right], vars} = Enum.map_reduce([left, right], vars, &pattern/2)
    {{left, right}, vars}
  end

  defp pattern(ast, vars), do: {literal(ast), vars}

  defp bind({name, _meta, _context}, vars) do
    variable = :"$#{map_size(vars) + 1}"
    {variable, Map.put(vars, name, variable)}
  end

  defp expr({name, _meta, context} = ast, vars) when is_atom(name) and is_atom(context) do
    case vars do
      %{^name => variable} -> variable
      _unbound -> unsupported!("`#{Macro.to_string(ast)}` is not bound by the parameter")
    end
  end

  defp expr({op, _meta, [left, right]}, vars) when is_map_key(@comparisons, op),
    do: {@comparisons[op], expr(left, vars), expr(right, vars)}

  defp expr({op, _meta, [left, right]}, vars) when is_map_key(@booleans, op),
    do: {@booleans[op], expr(left, vars), expr(right, vars)}

  defp expr({:not, _meta, [arg]}, vars), do: {:not, expr(arg, vars)}
  defp expr({check, _meta, [arg]}, vars) when check in @type_checks, do: {check, expr(arg, vars)}

  defp expr(list, vars) when is_list(list) do
    {list, _vars} = list_of(list, vars, &{expr(&1, &2), &2})
    list
  end

  defp expr({:{}, _meta, elements}, vars),
    do: {elements |> Enum.map(&expr(&1, vars)) |> List.to_tuple()}

  defp expr({:%{}, _meta, pairs}, vars) do
    Map.new(pairs, fn
      {key, value} -> {literal(key), expr(value, vars)}
      other -> unsupported_ast!(other)
    end)
  end

  defp expr({left, right}, vars), do: {{expr(left, vars), expr(right, vars)}}

  defp expr(atom, _vars) when is_atom(atom),
    do: if(MatchSpec.variable?(atom), do: {:const, atom}, else: atom)

  defp expr(ast, _vars), do: literal(ast)

  defp list_of([], vars, _translate), do: {[], vars}

  defp list_of([{:|, _meta, [head, tail]}], vars, translate) do
    {head, vars} = translate.(head, vars)
    {tail, vars} = translate.(tail, vars)
    {[head | tail], vars}
  end

  defp list_of([head | rest], vars, translate) do
    {head, vars} = translate.(head, vars)
    {rest, vars} = list_of(rest, vars, translate)
    {[head | rest], vars}
  end

  defp literal({:-, _meta, [number]}) when is_number(number), do: -number

  defp literal(atom) when is_atom(atom) do
    if MatchSpec.variable?(atom),
      do: unsupported!("#{inspect(atom)} is reserved for match variables"),
      else: atom
  end

  defp literal(value) when is_number(value) or is_binary(value), do: value
  defp literal(ast), do: unsupported_ast!(ast)

  defp unsupported_ast!(ast), do: unsupported!("`#{Macro.to_string(ast)}` is not supported")

  defp variable_ast?({name, _meta, context}), do: is_atom(name) and is_atom(context)
  defp variable_ast?(_ast), do: false

  defp syntax_message({prefix, suffix}, token), do: prefix <> token <> suffix
  defp syntax_message(message, token), do: message <> token

  defp unsupported!(message), do: throw({:unsupported, message})
end
