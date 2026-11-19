defmodule Voyager.MatchSpec do
  @moduledoc """
  Reads a match spec, without evaluating anything, and checks it in steps the caller composes:

      with {:ok, spec} <- MatchSpec.parse_fun(input, :elixir, :trace),
           :ok <- MatchSpec.check_clauses(spec, 10),
           :ok <- MatchSpec.check_actions(spec, [:return_trace]),
           :ok <- MatchSpec.check_compiles(spec, :trace) do
        {:ok, MatchSpec.encode(spec)}
      end

  A spec arrives either as an Erlang term (`parse/1`) or as a function written in Erlang or
  Elixir (`parse_fun/3`). Both read at most 4096 bytes of UTF-8, refuse when the atom table is
  close to full, and create the atoms the input names on this node.

  Every check returns `{:error, :invalid_shape}` for a term that is not a non-empty list of
  `{head, [guard], [body]}` clauses, so leaving `check_shape/1` out never raises. Errors are
  reasons; `format_error/1` turns them into messages for the user.
  """

  alias Voyager.MatchSpec.ElixirParser
  alias Voyager.MatchSpec.ErlangParser

  @max_bytes 4_096
  @atom_headroom 10_000
  @atom_tag :"$voyager_atom"

  @type t :: [{term(), [term()], [term()]}]
  @type type :: :table | :trace
  @type reason ::
          :too_large
          | :atom_table_full
          | {:syntax, String.t()}
          | {:unsupported, String.t()}
          | :invalid_shape
          | {:too_many_clauses, pos_integer()}
          | {:refused_action, atom()}
          | {:compile, [String.t()]}
          | {:unknown_atom, String.t()}

  @doc """
  Turns `"[{{'$1', active}, [], ['$1']}]"` into the term it spells, of any shape.

  A missing trailing `.` is added. Calls, operators, variables and sized binary segments such
  as `<<X:8>>` are syntax errors.
  """
  @spec parse(String.t()) :: {:ok, term()} | {:error, reason()}
  def parse(source) when is_binary(source) do
    with :ok <- check_input(source), do: ErlangParser.parse_term(source)
  end

  @doc """
  Turns a function written as text into a match spec, as `ets:fun2ms/1` and `dbg:fun2ms/1` do
  at compile time.

  `source` is one anonymous function with one parameter per clause, in `language`:

    * `:erlang` - `fun({K, V}) when V > 10 -> K end`, translated by `:ms_transform`, so
      anything `ets:fun2ms/1` or `dbg:fun2ms/1` accepts in a shell works, except remote calls,
      sized binary segments, `bsl` and `bsr`.
    * `:elixir` - `fn {k, v} when v > 10 -> k end`. Supports patterns of literals, variables,
      `_` (anything; `_name` is a variable like any other), lists, tuples and maps; guards of
      comparisons, `and`, `or`, `not` and `is_*` type
      checks, with each extra `when` becoming its own clause; bodies of bound variables and
      literals.

  `type` says what the parameter matches, and so the head of each clause:

    * `:table` - an ETS row, so a tuple or a variable. The body is what the match returns.
    * `:trace` - the list of a call's arguments, so a list or a variable. The body holds
      the trace actions; `true` just selects the call.

  Variables are numbered `'$1'`, `'$2'`, ... in the order they first appear in the head, and a
  variable used twice must be equal in both places. A variable the head does not bind is an
  `{:unsupported, message}` error.
  """
  @spec parse_fun(String.t(), :erlang | :elixir, type()) :: {:ok, t()} | {:error, reason()}
  def parse_fun(source, language, type)
      when is_binary(source) and language in [:erlang, :elixir] and type in [:table, :trace] do
    with :ok <- check_input(source) do
      case language do
        :erlang -> ErlangParser.parse_fun(source, type)
        :elixir -> ElixirParser.parse_fun(source, type)
      end
    end
  end

  @doc "Checks the spec is a non-empty proper list of `{head, [guard], [body]}` clauses."
  @spec check_shape(term()) :: :ok | {:error, :invalid_shape}
  def check_shape(spec), do: if(clauses?(spec), do: :ok, else: {:error, :invalid_shape})

  @doc """
  Checks the spec has at most `max` clauses: `1` for `ets_select_spec/5` on the agent, `10`
  for `trace_start/3`.
  """
  @spec check_clauses(term(), pos_integer()) :: :ok | {:error, reason()}
  def check_clauses(spec, max) when is_integer(max) and max > 0 do
    with :ok <- check_shape(spec) do
      if length(spec) <= max, do: :ok, else: {:error, {:too_many_clauses, max}}
    end
  end

  @doc """
  Refuses a tuple whose first element is in `refused` at any depth of the guards or body, the
  same walk the agent does, so `[:return_trace, :exception_trace]` refuses return tracing
  however deep it is written. Heads are patterns, never actions, so they are not walked.
  """
  @spec check_actions(term(), [atom()]) :: :ok | {:error, reason()}
  def check_actions(spec, refused) when is_list(refused) do
    with :ok <- check_shape(spec),
         nil <- refused(for({_head, guards, body} <- spec, do: guards ++ body), refused) do
      :ok
    else
      {:error, :invalid_shape} = error -> error
      action -> {:error, {:refused_action, action}}
    end
  end

  @doc """
  Compiles the spec with `:erlang.match_spec_test/3` for `type`, catching unknown guard
  functions, unbound variables and actions the type does not allow (`message` in a `:table`
  spec). A `false` guard is put first, so the body never runs on this node.
  """
  @spec check_compiles(term(), type()) :: :ok | {:error, reason()}
  def check_compiles(spec, type) when type in [:table, :trace] do
    with :ok <- check_shape(spec) do
      # `match_spec_test/3` runs the body on this node, and `{enable_trace, _}` segfaults it.
      silenced = for {head, guards, body} <- spec, do: {head, [false | guards], body}

      case :erlang.match_spec_test(test_object(type), silenced, type) do
        {:ok, _result, _flags, _warnings} -> :ok
        {:error, errors} -> {:error, {:compile, Enum.map(errors, &to_string(elem(&1, 1)))}}
      end
    end
  end

  @doc """
  Replaces every atom but a match variable with `{:"$voyager_atom", name}`, which the agent
  resolves against the atoms its node already has, so sending the spec creates none there.
  """
  @spec encode(term()) :: term()
  def encode(atom) when is_atom(atom) do
    if variable?(atom), do: atom, else: {@atom_tag, Atom.to_string(atom)}
  end

  def encode([head | tail]), do: [encode(head) | encode(tail)]

  def encode(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> encode() |> List.to_tuple()

  def encode(map) when is_map(map), do: Map.new(map, fn {k, v} -> {encode(k), encode(v)} end)
  def encode(term), do: term

  @spec format_error(reason()) :: String.t()
  def format_error(:too_large), do: "longer than #{@max_bytes} bytes"
  def format_error(:atom_table_full), do: "atom table exhausted"
  def format_error({:syntax, detail}), do: detail
  def format_error({:unsupported, detail}), do: detail
  def format_error(:invalid_shape), do: "expected a list of {head, guards, body} clauses"
  def format_error({:too_many_clauses, 1}), do: "expected one {head, guards, body} clause"
  def format_error({:too_many_clauses, max}), do: "expected at most #{max} clauses"
  def format_error({:refused_action, action}), do: "the #{action} action is not allowed"
  def format_error({:compile, errors}), do: Enum.join(errors, " ")
  def format_error({:unknown_atom, name}), do: "atom '#{name}' does not exist on the node"

  @doc "True for an atom a match spec may read as a variable: `_`, `$_`, `$$` and `$<digits>`."
  @spec variable?(atom()) :: boolean()
  # Wider than ERTS (`'$007'` is a constant there): an untagged constant keeps its meaning,
  # while a tagged variable the node lacks would be refused.
  def variable?(atom) when atom in [:_, :"$_", :"$$"], do: true
  def variable?(atom) when is_atom(atom), do: String.match?(Atom.to_string(atom), ~r/\A\$\d+\z/)

  defp check_input(source) do
    cond do
      byte_size(source) > @max_bytes -> {:error, :too_large}
      not String.valid?(source) -> {:error, {:syntax, "not valid UTF-8"}}
      not atom_headroom?() -> {:error, :atom_table_full}
      true -> :ok
    end
  end

  # Parsing interns every atom the input names here, and a full atom table aborts the VM.
  defp atom_headroom? do
    :erlang.system_info(:atom_limit) - :erlang.system_info(:atom_count) > @atom_headroom
  end

  defp clauses?([{_head, guards, body} | rest]) when is_list(guards) and is_list(body) do
    not List.improper?(guards) and not List.improper?(body) and (rest == [] or clauses?(rest))
  end

  defp clauses?(_term), do: false

  defp refused(term, refused) when is_tuple(term) and tuple_size(term) > 0 do
    action = elem(term, 0)
    if action in refused, do: action, else: refused(Tuple.to_list(term), refused)
  end

  defp refused([head | tail], refused), do: refused(head, refused) || refused(tail, refused)
  defp refused(map, refused) when is_map(map), do: refused(Map.to_list(map), refused)
  defp refused(_term, _refused), do: nil

  defp test_object(:table), do: {}
  defp test_object(:trace), do: []
end
