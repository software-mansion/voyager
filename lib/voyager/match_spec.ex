defmodule Voyager.MatchSpec do
  @moduledoc """
  Reads a match spec, without evaluating anything, and checks it in steps the caller composes:

      with {:ok, spec} <- MatchSpec.parse_fun(input, :elixir, :trace),
           :ok <- MatchSpec.check_clauses(spec, 10),
           :ok <- MatchSpec.check_actions(spec, Tracer.Refusals.refused_actions()),
           :ok <- MatchSpec.check_compiles(spec, :trace),
           encoded = MatchSpec.encode(spec),
           :ok <- MatchSpec.check_size(encoded, MatchSpec.Refusals.max_match_spec_bytes()) do
        {:ok, encoded}
      end

  What a spec may hold is OTP's to say:
  [Match Specifications in Erlang](https://www.erlang.org/doc/apps/erts/match_spec.html) for a
  term, [`ms_transform`](https://www.erlang.org/doc/apps/stdlib/ms_transform.html) for a
  function. Limits and refused actions are the caller's to pass. 

  `parse/1` and `parse_fun/3` create the atoms on this node.

  ## Limits

  A few bytes of input can ask for a lot of memory, so both parsers enforce:

    * **4096 bytes of UTF-8 input**: `{:error, :too_large}` above it.
    * **10 000 free atoms**: `{:error, :atom_table_full}` below it.
    * **524 288 bits per binary segment** (size × unit), the agent's `MAX_MATCH_SPEC_BYTES`.
      Checked before parsing: one segment is a single allocation `max_heap_size` cannot
      interrupt.
    * **8 MiB and 2 seconds per parse**: `{:error, :limit_exceeded}` past either.
    * **No `!` operator**: `:ms_transform` folds constant operators, so `init ! {stop, stop}`
      in an Erlang fun would really send.

  A `parse_fun/3` result always passes `check_shape/1`.
  """

  alias Voyager.MatchSpec.ElixirParser
  alias Voyager.MatchSpec.ErlangParser

  @max_bytes 4_096
  @atom_headroom 10_000
  @atom_tag :"$voyager_atom"
  @max_parse_megabytes 8
  @parse_timeout 2_000
  @max_variable 1_000

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
          | {:too_large, pos_integer()}
          | {:refused_action, atom()}
          | {:compile, [String.t()]}
          | {:unknown_atom, String.t()}

  @doc """
  A missing trailing `.` is added. Calls, operators and variables are syntax errors.
  """
  @spec parse(String.t()) :: {:ok, term()} | {:error, reason()}
  def parse(source) when is_binary(source) do
    with :ok <- check_input(source), do: bounded(fn -> ErlangParser.parse_term(source) end)
  end

  @doc """
  Turns one anonymous function written as text into a match spec, with
  [`ms_transform`](https://www.erlang.org/doc/apps/stdlib/ms_transform.html).

  An `:elixir` function is compiled to its Erlang form without being evaluated, then translated
  like an Erlang one, with trace actions called as in Erlang (`return_trace()`). Expanding
  other code would run it on this node, so the only macros are `and`, `or`, `in`, `..`,
  `is_nil/1` and `is_struct/1,2`.
  `import`, `require`, `%Name{}` (match `%{__struct__: Name}` instead) and calls to any module 
  but `:erlang` are `{:unsupported, message}`.

  `"abc"` is a binary in Elixir and a list in Erlang. 
  An Erlang binary of non-ASCII text needs its encoding, 
  `<<"zażółć"/utf8>>`: without it each character is cut to one byte.

  `bindings()` compiles to `'$*'`, which ERTS returns as that atom; only `'$$'` in a term is
  the list of bound variables.
  """
  @spec parse_fun(String.t(), :erlang | :elixir, type()) :: {:ok, t()} | {:error, reason()}
  def parse_fun(source, language, type)
      when is_binary(source) and language in [:erlang, :elixir] and type in [:table, :trace] do
    parser = if language == :erlang, do: ErlangParser, else: ElixirParser
    with :ok <- check_input(source), do: bounded(fn -> parser.parse_fun(source, type) end)
  end

  @doc "Checks the spec is a non-empty proper list of `{head, [guard], [body]}` clauses."
  @spec check_shape(term()) :: :ok | {:error, :invalid_shape}
  def check_shape([{_head, guards, body} | rest]) when is_list(guards) and is_list(body) do
    cond do
      List.improper?(guards) or List.improper?(body) -> {:error, :invalid_shape}
      rest == [] -> :ok
      true -> check_shape(rest)
    end
  end

  def check_shape(_spec), do: {:error, :invalid_shape}

  @doc """
  Checks the spec has at most `max` clauses. Use after `check_shape/1`.
  """
  @spec check_clauses(t(), pos_integer()) :: :ok | {:error, reason()}
  def check_clauses(spec, max) when is_integer(max) and max > 0 do
    if length(spec) <= max, do: :ok, else: {:error, {:too_many_clauses, max}}
  end

  @doc """
  Refuses actions which are in `refused` at any depth of the guards or body.
  Heads are patterns, never actions, so they are not walked. Use after `check_shape/1`.
  """
  @spec check_actions(t(), [atom()]) :: :ok | {:error, reason()}
  def check_actions(spec, refused) when is_list(refused) do
    case refused(for({_head, guards, body} <- spec, do: guards ++ body), refused) do
      nil -> :ok
      action -> {:error, {:refused_action, action}}
    end
  end

  @doc """
  Compiles the spec with `:erlang.match_spec_test/3` for `type`, catching unknown guard
  functions, unbound variables and actions the type does not allow (`message` in a `:table`
  spec). A `false` guard is put first, so the body never runs on this node. Use after
  `check_shape/1`.
  """
  @spec check_compiles(t(), type()) :: :ok | {:error, reason()}
  def check_compiles(spec, type) when type in [:table, :trace] do
    # `match_spec_test/3` runs the body on this node, and `{enable_trace, _}` segfaults it.
    silenced = for {head, guards, body} <- spec, do: {head, [false | guards], body}

    case :erlang.match_spec_test(test_object(type), silenced, type) do
      {:ok, _result, _flags, _warnings} -> :ok
      {:error, errors} -> {:error, {:compile, Enum.map(errors, &to_string(elem(&1, 1)))}}
    end
  end

  @doc """
  Checks the term is at most `max_bytes` in the external term format. Agent also checks it so after encode.
  """
  @spec check_size(term(), pos_integer()) :: :ok | {:error, reason()}
  def check_size(term, max_bytes) when is_integer(max_bytes) and max_bytes > 0 do
    if :erlang.external_size(term) <= max_bytes, do: :ok, else: {:error, {:too_large, max_bytes}}
  end

  @doc """
  Replaces every atom but a match variable with `{:"$voyager_atom", name}`, which the agent
  resolves against the atoms its node already has, so sending the spec creates none there.
  Only `_`, `$_`, `$$` and `$0` to `$1000` stay atoms.
  """
  @spec encode(term()) :: term()
  def encode(atom) when is_atom(atom) do
    if variable?(atom), do: atom, else: {@atom_tag, Atom.to_string(atom)}
  end

  def encode([head | tail]), do: [encode(head) | encode(tail)]

  def encode(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> encode() |> List.to_tuple()

  # `Map.new/2` would dispatch `Enumerable` on a `__struct__` key, running a `File.Stream` read.
  def encode(map) when is_map(map),
    do: :maps.from_list(for {k, v} <- :maps.to_list(map), do: {encode(k), encode(v)})

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
  def format_error({:too_large, max_bytes}), do: "encodes to more than #{max_bytes} bytes"
  def format_error({:refused_action, action}), do: "the #{action} action is not allowed"
  def format_error({:compile, errors}), do: Enum.join(errors, " ")
  def format_error({:unknown_atom, name}), do: "atom '#{name}' does not exist on the node"

  # ERTS also reads `$1001` and up as variables; tagged, the agent keeps them only if the node
  # has them, so the atoms a spec can create on a node are this fixed set.
  defp variable?(atom) when atom in [:_, :"$_", :"$$"], do: true

  defp variable?(atom) do
    with "$" <> digits <- Atom.to_string(atom),
         {number, ""} when number in 0..@max_variable <- Integer.parse(digits) do
      Integer.to_string(number) == digits
    else
      _other -> false
    end
  end

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
