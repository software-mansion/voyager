defmodule Voyager.MatchSpec do
  @moduledoc """
  Reads a match spec written as an Erlang term, without evaluating it, and checks it in steps
  the caller composes:

      with {:ok, spec} <- MatchSpec.parse(input),
           :ok <- MatchSpec.check_clauses(spec, 10),
           :ok <- MatchSpec.check_actions(spec, [:return_trace]),
           :ok <- MatchSpec.check_compiles(spec, :trace) do
        {:ok, MatchSpec.encode(spec)}
      end

  Every check returns `{:error, :invalid_shape}` for a term that is not a non-empty list of
  `{head, [guard], [body]}` clauses, so leaving `check_shape/1` out never raises. Errors are
  reasons; `format_error/1` turns them into messages for the user.
  """

  @max_bytes 4_096
  @atom_headroom 10_000
  @atom_tag :"$voyager_atom"

  @type t :: [{term(), [term()], [term()]}]
  @type reason ::
          :too_large
          | :atom_table_full
          | {:syntax, String.t()}
          | :invalid_shape
          | {:too_many_clauses, pos_integer()}
          | {:refused_action, atom()}
          | {:compile, [String.t()]}
          | {:unknown_atom, String.t()}

  @doc """
  Turns `"[{{'$1', active}, [], ['$1']}]"` into the term it spells, of any shape.

  A missing trailing `.` is added. Creates the atoms the string names on this node.
  """
  @spec parse(String.t()) :: {:ok, term()} | {:error, reason()}
  def parse(string) when is_binary(string) and byte_size(string) > @max_bytes,
    do: {:error, :too_large}

  def parse(string) when is_binary(string) do
    cond do
      not String.valid?(string) -> {:error, {:syntax, "not valid UTF-8"}}
      not atom_headroom?() -> {:error, :atom_table_full}
      true -> parse_term(string)
    end
  end

  @spec check_shape(term()) :: :ok | {:error, :invalid_shape}
  def check_shape(spec), do: if(clauses?(spec), do: :ok, else: {:error, :invalid_shape})

  @spec check_clauses(term(), pos_integer()) :: :ok | {:error, reason()}
  def check_clauses(spec, max) when is_integer(max) and max > 0 do
    with :ok <- check_shape(spec) do
      if length(spec) <= max, do: :ok, else: {:error, {:too_many_clauses, max}}
    end
  end

  @doc "Refuses a tuple whose first element is in `refused` at any depth of the guards or body."
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

  @doc "Compiles the spec as `:erlang.match_spec_test/3` would for `type`, without running its body."
  @spec check_compiles(term(), :table | :trace) :: :ok | {:error, reason()}
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
  def format_error(:invalid_shape), do: "expected a list of {head, guards, body} clauses"
  def format_error({:too_many_clauses, 1}), do: "expected one {head, guards, body} clause"
  def format_error({:too_many_clauses, max}), do: "expected at most #{max} clauses"
  def format_error({:refused_action, action}), do: "the #{action} action is not allowed"
  def format_error({:compile, errors}), do: Enum.join(errors, " ")
  def format_error({:unknown_atom, name}), do: "atom '#{name}' does not exist on the node"

  defp parse_term(string) do
    charlist = string |> terminate() |> String.to_charlist()

    with {:ok, tokens, _end} <- :erl_scan.string(charlist),
         :ok <- refuse_colons(tokens),
         {:ok, term} <- :erl_parse.parse_term(tokens) do
      {:ok, term}
    else
      {:error, {:syntax, _detail}} = error -> error
      {:error, reason, _end} -> {:error, {:syntax, format_syntax(reason)}}
      {:error, reason} -> {:error, {:syntax, format_syntax(reason)}}
    end
  end

  # `:erl_scan` interns every atom it reads here, and a full atom table aborts the VM.
  defp atom_headroom? do
    :erlang.system_info(:atom_limit) - :erlang.system_info(:atom_count) > @atom_headroom
  end

  # `:erl_parse.parse_term/1` builds `<<0:99999999999999>>`, so 20 bytes could exhaust memory.
  defp refuse_colons(tokens) do
    if List.keymember?(tokens, :":", 0),
      do: {:error, {:syntax, "calls and sized binary segments are not allowed"}},
      else: :ok
  end

  defp terminate(string) do
    string |> String.trim_trailing() |> String.trim_trailing(".") |> Kernel.<>(".")
  end

  defp format_syntax({_location, module, description}) when is_atom(module) do
    description |> module.format_error() |> to_string()
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

  # Wider than ERTS (`'$007'` is a constant there): an untagged constant keeps its meaning,
  # while a tagged variable the node lacks would be refused.
  defp variable?(atom) when atom in [:_, :"$_", :"$$"], do: true
  defp variable?(atom), do: String.match?(Atom.to_string(atom), ~r/\A\$\d+\z/)
end
