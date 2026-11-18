defmodule Voyager.Services.Tracer.MatchSpec do
  @moduledoc """
  Turns a function written as text into the match spec `trace:function/4` takes, without
  calling anything in it: `fn [a, _] when a > 10 -> true end` and
  `fun([A, _]) when A > 10 -> true end` both become `[{[:"$1", :_], [{:>, :"$1", 10}], []}]`.

  The function takes one parameter, the list of call arguments or a variable bound to the
  whole list, and only selects calls: every body must be `true`. Unlike `dbg:fun2ms` it runs
  on text at runtime, takes no variables from the environment, knows no record definitions
  and allows no body actions.

  An Erlang `fun` goes through `:ms_transform`, the transform behind `dbg:fun2ms`, so it
  accepts what `dbg:fun2ms` accepts in a shell, less the atoms a match spec reserves (`'_'`,
  `'$1'`) and sized or typed bit syntax. An Elixir `fn` has no such transform and is
  translated by `Voyager.Services.Tracer.MatchSpec.ElixirParser` from an allow-list of
  patterns and guards, with Elixir's operators and guards mapped to their match spec forms.
  Its guard calls are checked by the emulator rather than by `:ms_transform`'s table, so it
  accepts a few guards the Erlang form does not, such as `tuple_size/1` and `is_boolean/1`.

  Either result is then compiled with `:erlang.match_spec_test/3`, which has the final say.
  """

  alias Voyager.Services.Tracer.MatchSpec.ElixirParser
  alias Voyager.Services.Tracer.MatchSpec.ErlangParser

  @atom_tag :"$voyager_atom"

  @type spec :: [{term(), [term()], []}]

  @doc """
  Parses `source` for a function of `arity`, or of any arity when `nil`.

  A source starting with `fun` is read as Erlang and one starting with `fn` as Elixir.
  Creates the atoms the source names on this node. Errors are messages for the user.
  """
  @spec parse(String.t(), arity() | nil) :: {:ok, spec()} | {:error, String.t()}
  def parse(source, arity) when is_binary(source) do
    with {:ok, spec} <- translate(source),
         :ok <- validate(spec, arity),
         :ok <- compile(spec) do
      {:ok, for({head, guards, [true]} <- spec, do: {head, guards, []})}
    end
  end

  @doc """
  Replaces the atoms of a parsed spec with `{:"$voyager_atom", name}`, which the agent
  resolves against the atoms already on the node, so no atom the user named is created there.
  """
  @spec encode(spec()) :: spec()
  def encode(spec), do: for({head, guards, body} <- spec, do: {tag(head), tag(guards), body})

  defp translate(source) do
    if String.valid?(source) do
      case String.trim_leading(source) do
        "fun" <> _rest -> ErlangParser.parse(source)
        "fn" <> _rest -> ElixirParser.parse(source)
        _other -> {:error, "expected an Elixir `fn ... end` or an Erlang `fun ... end`"}
      end
    else
      {:error, "not valid UTF-8"}
    end
  end

  defp validate(spec, arity) do
    case Enum.find_value(spec, &clause_error(&1, arity)) do
      nil -> :ok
      message -> {:error, message}
    end
  end

  defp clause_error({head, guards, body}, arity) do
    cond do
      body != [true] ->
        body_error(body)

      not (is_list(head) or variable?(head)) ->
        "the argument must be a list of call arguments or a variable"

      wrong_arity?(head, arity) ->
        "expected #{arity} arguments, got #{min_length(head)}"

      reserved = reserved_atom({head, guards}) ->
        "the atom #{inspect(reserved)} is reserved in a match spec"

      true ->
        nil
    end
  end

  defp wrong_arity?(head, arity) when is_integer(arity) and is_list(head) do
    if List.improper?(head), do: min_length(head) > arity, else: length(head) != arity
  end

  defp wrong_arity?(_head, _arity), do: false

  defp min_length([_ | tail]), do: 1 + min_length(tail)
  defp min_length(_tail), do: 0

  defp body_error([{action}]) when action in [:return_trace, :exception_trace],
    do: "#{action}() is not allowed, set return tracing on the session"

  defp body_error(_body),
    do: "the body must be `true`, the match spec only selects which calls are traced"

  # A leading `false` guard keeps match_spec_test/3 from running the user's guards here.
  defp compile(spec) do
    case :erlang.match_spec_test([], for({h, g, b} <- spec, do: {h, [false | g], b}), :trace) do
      {:ok, _result, _flags, _warnings} -> :ok
      {:error, errors} -> {:error, Enum.map_join(errors, "; ", &to_string(elem(&1, 1)))}
    end
  end

  defp reserved_atom(atom) when is_atom(atom) do
    if String.starts_with?(Atom.to_string(atom), "$") and not variable?(atom), do: atom
  end

  defp reserved_atom([head | tail]), do: reserved_atom(head) || reserved_atom(tail)
  defp reserved_atom(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> reserved_atom()
  defp reserved_atom(map) when is_map(map), do: map |> Map.to_list() |> reserved_atom()
  defp reserved_atom(_term), do: nil

  defp variable?(atom), do: is_atom(atom) and Atom.to_string(atom) =~ ~r/\A(_|\$(\d+|_|\$))\z/

  # Guard function names are tagged too: they exist on every node and decode back unchanged.
  defp tag(atom) when is_atom(atom),
    do: if(variable?(atom), do: atom, else: {@atom_tag, Atom.to_string(atom)})

  defp tag([head | tail]), do: [tag(head) | tag(tail)]
  defp tag(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> tag() |> List.to_tuple()

  defp tag(map) when is_map(map),
    do: map |> Map.to_list() |> Map.new(fn {key, value} -> {tag(key), tag(value)} end)

  defp tag(term), do: term
end
