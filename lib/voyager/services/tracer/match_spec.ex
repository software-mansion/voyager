defmodule Voyager.Services.Tracer.MatchSpec do
  @moduledoc """
  Translates a trace match spec written as an Elixir `fn` into the term
  `trace:function/4` takes: `fn [a, _] when a > 10 -> true end` becomes
  `[{[:"$1", :_], [{:>, :"$1", 10}], []}]`.

  The source is quoted, never evaluated, and only an allow-list of patterns and
  guards is translated. The `fn` only selects calls, so every body must be `true`.
  Atoms come out as `{:"$voyager_atom", name}` and are resolved by the agent
  against the atoms that already exist on the node, so none are created on either side.
  """

  alias Voyager.Services.Tracer.Refusals

  @atom_tag :"$voyager_atom"
  @max_bytes 4_096
  @max_clauses 10
  @max_vars 32
  @min_int -0x8000000000000000
  @max_int 0x7FFFFFFFFFFFFFFF
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
    /: :/
  }

  @guard_functions Map.new(
                     [
                       is_atom: 1,
                       is_binary: 1,
                       is_bitstring: 1,
                       is_boolean: 1,
                       is_float: 1,
                       is_function: 1,
                       is_function: 2,
                       is_integer: 1,
                       is_list: 1,
                       is_map: 1,
                       is_number: 1,
                       is_pid: 1,
                       is_port: 1,
                       is_reference: 1,
                       is_tuple: 1,
                       abs: 1,
                       hd: 1,
                       tl: 1,
                       length: 1,
                       map_size: 1,
                       tuple_size: 1,
                       byte_size: 1,
                       bit_size: 1,
                       round: 1,
                       trunc: 1,
                       ceil: 1,
                       floor: 1,
                       min: 2,
                       max: 2,
                       div: 2,
                       rem: 2,
                       binary_part: 3,
                       node: 0,
                       node: 1,
                       self: 0
                     ],
                     fn {name, arity} -> {{Atom.to_string(name), arity}, name} end
                   )

  @products [:*, :div, :rem]

  @type spec :: [{term(), [term()], []}]

  @doc """
  Translates `source` for a function of `arity`, or of any arity when `nil`.

  Errors are messages naming the offending construct and its position.
  """
  @spec parse(String.t(), arity() | nil) :: {:ok, spec()} | {:error, String.t()}
  def parse(source, _arity) when is_binary(source) and byte_size(source) > @max_bytes,
    do: {:error, "longer than #{@max_bytes} bytes"}

  def parse(source, arity) when is_binary(source) do
    {:ok, source |> quote!() |> spec(arity)}
  catch
    {:invalid, message} -> {:error, message}
  end

  defp quote!(source) do
    opts = [static_atoms_encoder: &encode_atom/2, emit_warnings: false, columns: true]

    case Code.string_to_quoted(source, opts) do
      {:ok, ast} -> ast
      {:error, {meta, message, token}} -> invalid!(error_message(message, token), meta)
    end
  end

  defp encode_atom(name, _meta), do: {:ok, {@atom_tag, name}}

  defp error_message({prefix, suffix}, token), do: prefix <> token <> suffix
  defp error_message(message, token), do: message <> token

  defp spec({:fn, meta, clauses}, _arity) when length(clauses) > @max_clauses,
    do: invalid!("at most #{@max_clauses} clauses", meta)

  defp spec({:fn, _meta, clauses}, arity) do
    spec = Enum.map(clauses, &clause(&1, arity))
    max_products = Refusals.max_products()

    if products(Enum.map(spec, &elem(&1, 1))) > max_products,
      do: invalid!("at most #{max_products} `*`, `div` and `rem` in a match spec")

    spec
  end

  defp spec(_ast, _arity), do: invalid!("expected an fn such as `#{@example}`")

  defp clause({:->, meta, [[{:when, _when, [args, guard]}], body]}, arity) do
    if match?({:when, _, _}, guard),
      do: invalid!("use a single `when`, combining conditions with `or`", meta)

    {head, vars} = head(args, arity, meta)
    body!(body, meta)
    {head, [expr(guard, vars)], []}
  end

  defp clause({:->, meta, [[args], body]}, arity) do
    {head, _vars} = head(args, arity, meta)
    body!(body, meta)
    {head, [], []}
  end

  defp clause({:->, meta, _}, _arity),
    do: invalid!("an fn clause takes one argument, the list of call arguments", meta)

  defp head(args, arity, meta) when is_list(args) do
    if is_integer(arity) and not match?({:|, _, _}, List.last(args)) and length(args) != arity,
      do: invalid!("expected #{arity} arguments, got #{length(args)}", meta)

    pattern(args, %{})
  end

  defp head({{@atom_tag, name}, _var_meta, context}, _arity, _meta) when is_atom(context),
    do: bind(name, %{})

  defp head(_args, _arity, meta),
    do: invalid!("the argument must be a list of call arguments or a variable", meta)

  defp body!(true, _meta), do: :ok

  defp body!({{@atom_tag, trace}, _call_meta, []}, meta)
       when trace in ["return_trace", "exception_trace"],
       do: invalid!("#{trace}() is not allowed, set return tracing on the session", meta)

  defp body!(_body, meta),
    do:
      invalid!(
        "the body must be `true`, the match spec only selects which calls are traced",
        meta
      )

  defp pattern({@atom_tag, _name} = atom, vars), do: {literal!(atom), vars}

  defp pattern({{@atom_tag, name}, _meta, context}, vars) when is_atom(context),
    do: bind(name, vars)

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

  defp pattern({left, right}, vars) do
    {elements, vars} = pattern([left, right], vars)
    {List.to_tuple(elements), vars}
  end

  defp pattern({:{}, _meta, elements}, vars) do
    {elements, vars} = pattern(elements, vars)
    {List.to_tuple(elements), vars}
  end

  defp pattern({:%{}, _meta, pairs}, vars) do
    {pairs, vars} = Enum.map_reduce(pairs, vars, &pair/2)
    {Map.new(pairs), vars}
  end

  defp pattern({:%, _meta, [module, {:%{}, _, _} = map]}, vars) do
    {map, vars} = pattern(map, vars)
    {Map.put(map, {@atom_tag, "__struct__"}, literal!(module)), vars}
  end

  defp pattern(ast, vars), do: {literal!(ast), vars}

  defp pair({key, value}, vars) do
    {value, vars} = pattern(value, vars)
    {{literal!(key), value}, vars}
  end

  defp pair(ast, _vars), do: unsupported!(ast)

  defp bind("_" <> _, vars), do: {:_, vars}
  defp bind(name, vars) when is_map_key(vars, name), do: {Map.fetch!(vars, name), vars}

  defp bind(_name, vars) when map_size(vars) >= @max_vars,
    do: invalid!("at most #{@max_vars} variables per clause")

  defp bind(name, vars) do
    var = :"$#{map_size(vars) + 1}"
    {var, Map.put(vars, name, var)}
  end

  defp expr({@atom_tag, _name} = atom, _vars), do: literal!(atom)

  defp expr({{@atom_tag, name}, meta, context}, vars) when is_atom(context) do
    case vars do
      %{^name => var} -> var
      _unbound -> invalid!("unknown variable #{name}", meta)
    end
  end

  defp expr({{@atom_tag, name}, meta, args}, vars) when is_list(args),
    do: call(name, args, meta, vars)

  defp expr({:in, meta, [_, _]}, _vars),
    do: invalid!("`in` is not supported, write `x == a or x == b`", meta)

  defp expr({operator, _meta, [left, right]}, vars) when is_map_key(@operators, operator),
    do: {Map.fetch!(@operators, operator), expr(left, vars), expr(right, vars)}

  defp expr({:-, _meta, [number]} = ast, _vars) when is_number(number), do: literal!(ast)
  defp expr({:-, _meta, [operand]}, vars), do: {:-, expr(operand, vars)}
  defp expr({:not, _meta, [operand]}, vars), do: {:not, expr(operand, vars)}
  defp expr(list, vars) when is_list(list), do: Enum.map(list, &expr(&1, vars))
  defp expr({left, right}, vars), do: {{expr(left, vars), expr(right, vars)}}

  defp expr({:{}, _meta, elements}, vars),
    do: {elements |> Enum.map(&expr(&1, vars)) |> List.to_tuple()}

  defp expr(ast, _vars), do: literal!(ast)

  defp call("is_nil", [term], _meta, vars), do: {:"=:=", expr(term, vars), nil}

  defp call("elem", [tuple, index], _meta, vars),
    do: {:element, element_index(index, vars), expr(tuple, vars)}

  defp call("is_map_key", [map, key], _meta, vars),
    do: {:is_map_key, expr(key, vars), expr(map, vars)}

  defp call("map_get", [map, key], _meta, vars), do: {:map_get, expr(key, vars), expr(map, vars)}

  defp call(name, args, meta, vars) do
    case Map.fetch(@guard_functions, {name, length(args)}) do
      {:ok, function} -> List.to_tuple([function | Enum.map(args, &expr(&1, vars))])
      :error -> invalid!("#{name}/#{length(args)} is not allowed in a match spec", meta)
    end
  end

  # Elixir's `elem/2` counts from 0, the match spec's `element/2` from 1.
  defp element_index(index, _vars) when is_integer(index), do: literal!(index) + 1
  defp element_index(index, vars), do: {:+, expr(index, vars), 1}

  defp literal!({@atom_tag, name}), do: atom!(name)
  defp literal!({:-, _meta, [number]}) when is_number(number), do: literal!(-number)

  defp literal!(integer) when is_integer(integer) and integer not in @min_int..@max_int,
    do: invalid!("integers must fit in 64 bits")

  defp literal!(term) when is_number(term) or is_binary(term) or is_boolean(term) or is_nil(term),
    do: term

  defp literal!({:__aliases__, meta, segments}) do
    names =
      Enum.map(segments, fn
        {@atom_tag, name} -> name
        _dynamic -> invalid!("module names must be literal", meta)
      end)

    case names do
      ["Elixir" | _rest] -> atom!(Enum.join(names, "."))
      names -> atom!(Enum.join(["Elixir" | names], "."))
    end
  end

  defp literal!(ast), do: unsupported!(ast)

  defp atom!("$" <> _ = name), do: invalid!(":#{name} reads as a match spec variable")
  defp atom!("_"), do: invalid!(":_ reads as a match spec wildcard, write `_` instead")
  defp atom!(name), do: {@atom_tag, name}

  defp products(tuple) when is_tuple(tuple) and tuple_size(tuple) > 0 do
    own = if elem(tuple, 0) in @products, do: 1, else: 0
    own + products(Tuple.to_list(tuple))
  end

  defp products(list) when is_list(list), do: Enum.sum_by(list, &products/1)
  defp products(_term), do: 0

  defp unsupported!({{@atom_tag, name}, meta, args}) when is_list(args),
    do: invalid!("#{name}/#{length(args)} is not allowed in a match spec", meta)

  defp unsupported!({form, meta, _args}) when is_atom(form) and is_list(meta),
    do: invalid!("`#{form}` is not allowed in a match spec", meta)

  defp unsupported!({_form, meta, _args}) when is_list(meta),
    do: invalid!("this expression is not allowed in a match spec", meta)

  defp unsupported!(_term), do: invalid!("a literal in the match spec is not allowed")

  defp invalid!(message, meta),
    do: invalid!("#{message} at line #{meta[:line]}, column #{meta[:column]}")

  defp invalid!(message), do: throw({:invalid, message})
end
