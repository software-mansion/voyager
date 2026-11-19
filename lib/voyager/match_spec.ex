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
  Elixir (`parse_fun/3`). Both create the atoms the input names on this node.

  ## Limits

  Parsing builds the terms the input spells out, so a few bytes can ask for a lot of memory:
  `<<0:99999999999999>>` is terabytes, and `:ms_transform` folds `1 bsl 4000000` into a 488 KiB
  integer. Both `parse/1` and `parse_fun/3` therefore enforce:

    * **4096 bytes of UTF-8 input**: `{:error, :too_large}` above it.
    * **10 000 free atoms**: below that, `{:error, :atom_table_full}`, since a full atom table
      aborts the VM instead of raising.
    * **524 288 bits per binary segment** (size × unit): 64 KiB, the agent's
      `TRACE_MAX_MATCH_SPEC_BYTES`, so no segment is built that the agent would refuse anyway.
      It is checked before parsing, because one segment is a single allocation that
      `max_heap_size` cannot interrupt.
    * **8 MiB and 2 seconds per parse**: parsing runs in its own process with `max_heap_size`
      (binaries included), killed past either limit with `{:error, :limit_exceeded}`. 8 MiB is
      well above the 64 KiB a spec can be when sent, and small enough to cost nothing noticeable.
    * **No `!` operator**: `:ms_transform` folds it like any other operator, so
      `init ! {stop, stop}` in an Erlang fun would really send.

  Every check returns `{:error, :invalid_shape}` for a term that is not a non-empty list of
  `{head, [guard], [body]}` clauses, so leaving `check_shape/1` out never raises. Errors are
  reasons; `format_error/1` turns them into messages for the user.
  """

  alias Voyager.MatchSpec.ElixirParser
  alias Voyager.MatchSpec.ErlangParser

  @max_bytes 4_096
  @atom_headroom 10_000
  @atom_tag :"$voyager_atom"
  @max_parse_megabytes 8
  @parse_timeout 2_000

  @type t :: [{term(), [term()], [term()]}]
  @type type :: :table | :trace
  @type reason ::
          :too_large
          | :atom_table_full
          | :limit_exceeded
          | {:syntax, String.t()}
          | {:unsupported, String.t()}
          | :invalid_shape
          | {:too_many_clauses, pos_integer()}
          | {:refused_action, atom()}
          | {:compile, [String.t()]}
          | {:unknown_atom, String.t()}

  @doc """
  Turns `"[{{'$1', active}, [], ['$1']}]"` into the term it spells, of any shape.

  A missing trailing `.` is added. Calls, operators and variables are syntax errors. See
  [Limits](#module-limits) for the size limits.
  """
  @spec parse(String.t()) :: {:ok, term()} | {:error, reason()}
  def parse(source) when is_binary(source) do
    with :ok <- check_input(source), do: bounded(fn -> ErlangParser.parse_term(source) end)
  end

  @doc """
  Turns a function written as text into a match spec, as `ets:fun2ms/1` and `dbg:fun2ms/1` do
  at compile time.

  `source` is one anonymous function with one parameter per clause, in `language`:

    * `:erlang` - `fun({K, V}) when V > 10 -> K end`, translated by `:ms_transform`, so
      anything `ets:fun2ms/1` or `dbg:fun2ms/1` accepts in a shell works, within
      [Limits](#module-limits).
    * `:elixir` - `fn {k, v} when v > 10 -> k end`, compiled to the Erlang form of the same
      function without evaluating it, then translated by `:ms_transform` like an Erlang one.
      What Elixir compiles to something `fun2ms` accepts works: Kernel's operators and guards
      (`elem/2`, `is_map_key/2`, ...), `Bitwise`, `:erlang.name(...)`, a module name such as
      `MyApp.Repo`, and the trace actions, `object/0` and `bindings/0`, called as in Erlang.
      The only macros are `and`, `or`, `in`, `..`, `is_nil/1` and `is_struct/1,2`; `in`,
      `is_struct` and `map.key` work in guards only.

      Expanding other code would run it on this node, so `import`, `require`, `%Name{}`
      (match `%{__struct__: Name}` instead) and calls to any module but `:erlang` are
      `{:unsupported, message}`. So is a guard call Elixir does not allow in a guard, such as
      `get_tcw()`, and what `:ms_transform` does not know in either language, such as
      `tuple_size/1` and `is_boolean/1`.

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
    parser = if language == :erlang, do: ErlangParser, else: ElixirParser
    with :ok <- check_input(source), do: bounded(fn -> parser.parse_fun(source, type) end)
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

  def format_error(:limit_exceeded),
    do: "building it needs more than #{@max_parse_megabytes} MiB or #{@parse_timeout} ms"

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

  defp bounded(parse) do
    max_heap = %{
      size: div(@max_parse_megabytes * 1_048_576, :erlang.system_info(:wordsize)),
      kill: true,
      error_logger: false,
      # Binaries over 64 bytes live off-heap, so the size would not count them otherwise.
      include_shared_binaries: true
    }

    {pid, ref} =
      :erlang.spawn_opt(fn -> exit({:shutdown, parse.()}) end, [:monitor, max_heap_size: max_heap])

    receive do
      {:DOWN, ^ref, :process, ^pid, {:shutdown, result}} -> result
      {:DOWN, ^ref, :process, ^pid, _killed} -> {:error, :limit_exceeded}
    after
      @parse_timeout ->
        Process.demonitor(ref, [:flush])
        Process.exit(pid, :kill)
        {:error, :limit_exceeded}
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
