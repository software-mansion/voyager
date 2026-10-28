defmodule VoyagerWeb.TermFormatter.Erlang do
  @moduledoc """
  Prints terms in Erlang syntax with `erl_pp`, from an abstract form built
  here, so the output never depends on the VM's `+pc` flag. A list reads as a
  string only within ASCII; a binary within Unicode.
  """

  @behaviour VoyagerWeb.TermFormatter

  alias Voyager.Pid
  alias VoyagerWeb.TermFormatter

  @single_line 1_000_000_000
  @elision {:text, ~c"..."}

  @impl true
  def inspect(term, opts \\ []) do
    opts = Inspect.Opts.new(opts)
    {form, _opts} = abstract(term, opts)
    print(form, line_length(opts))
  end

  @doc """
  `term` uncut, with pids, refs and ports as calls that rebuild them, so it
  pastes into `erl`. Wraps at `:width`.
  """
  @impl true
  def copy_string(term, opts \\ []) do
    opts = Inspect.Opts.new([pretty: true] ++ opts)
    {form, _mode} = abstract(term, :copy)
    print(form, line_length(opts))
  end

  @impl true
  def format_mfa({mod, fun, arity}), do: "#{atom(mod)}:#{atom(fun)}/#{arity}"

  @spec atom(atom()) :: String.t()
  def atom(atom), do: atom |> :io_lib.write_atom() |> IO.chardata_to_string()

  defp print(form, line_length) do
    form
    |> :erl_pp.expr(hook: &text_hook/4, encoding: :unicode, linewidth: line_length)
    |> IO.chardata_to_string()
  end

  defp text_hook({:text, chars}, _indent, _precedence, _options), do: chars

  defp line_length(%Inspect.Opts{pretty: true, width: width}) when is_integer(width), do: width
  defp line_length(_opts), do: @single_line

  defp abstract(tuple, mode) when is_tuple(tuple) do
    {forms, more?, mode} = tuple |> Tuple.to_list() |> abstract_each(mode, &abstract/2)
    {{:tuple, anno(), forms ++ elision(more?)}, mode}
  end

  defp abstract(map, mode) when is_map(map) do
    {fields, more?, mode} = map |> :maps.to_list() |> abstract_each(mode, &field/2)
    elided = for elision <- elision(more?), do: {:map_field_assoc, anno(), elision, elision}
    {{:map, anno(), fields ++ elided}, mode}
  end

  defp abstract([_ | _] = list, mode) do
    case printable_prefix(list, printable_limit(mode)) do
      {:ok, chars, more?} -> {string(chars, more?), mode}
      :error -> cons(list, mode)
    end
  end

  defp abstract(bitstring, mode) when is_bitstring(bitstring) and bitstring != "" do
    case printable_prefix(bitstring, printable_limit(mode)) do
      {:ok, chars, more?} ->
        {{:bin, anno(), [string_element(chars) | elision_element(more?)]}, mode}

      :error ->
        {bytes(bitstring, limit(mode)), spend(mode, byte_size(bitstring))}
    end
  end

  defp abstract(term, mode), do: {leaf(term, mode), mode}

  defp leaf(id, :copy) when is_pid(id) or is_reference(id) or is_port(id) do
    {fun, arg} = TermFormatter.term_to_local_term(id)
    call(fun, :erl_parse.abstract(arg))
  end

  defp leaf(pid, _mode) when is_pid(pid), do: text(Pid.format(pid))
  defp leaf(ref, _mode) when is_reference(ref), do: text(:erlang.ref_to_list(ref))
  defp leaf(port, _mode) when is_port(port), do: text(:erlang.port_to_list(port))

  defp leaf(fun, mode) when is_function(fun) do
    case :erlang.fun_info(fun, :type) do
      {:type, :external} ->
        :erl_parse.abstract(fun)

      {:type, :local} when mode == :copy ->
        {:string, anno(), :erlang.fun_to_list(fun)}

      {:type, :local} ->
        text(:erlang.fun_to_list(fun))
    end
  end

  defp leaf(other, _mode), do: :erl_parse.abstract(other)

  # :limit is one budget for the whole term, spent depth-first one item at a time.
  defp abstract_each(items, mode, fun, acc \\ [])
  defp abstract_each([], mode, _fun, acc), do: {Enum.reverse(acc), false, mode}

  defp abstract_each(_items, %Inspect.Opts{limit: 0} = opts, _fun, acc),
    do: {Enum.reverse(acc), true, opts}

  defp abstract_each([item | items], mode, fun, acc) do
    {form, mode} = fun.(item, spend(mode, 1))
    abstract_each(items, mode, fun, [form | acc])
  end

  defp field({key, value}, mode) do
    {key, mode} = abstract(key, mode)
    {value, mode} = abstract(value, mode)
    {{:map_field_assoc, anno(), key, value}, mode}
  end

  defp spend(%Inspect.Opts{limit: limit} = opts, count) when is_integer(limit),
    do: %{opts | limit: max(limit - count, 0)}

  defp spend(mode, _count), do: mode

  defp limit(:copy), do: :infinity
  defp limit(%Inspect.Opts{limit: limit}), do: limit

  defp printable_limit(:copy), do: :infinity
  defp printable_limit(%Inspect.Opts{printable_limit: limit}), do: limit

  defp elision(true), do: [@elision]
  defp elision(false), do: []

  defp elision_element(more?) do
    for elision <- elision(more?), do: {:bin_element, anno(), elision, :default, :default}
  end

  defp string(chars, false), do: {:string, anno(), chars}
  defp string(chars, true), do: {:op, anno(), :++, {:string, anno(), chars}, @elision}

  # Cons expression `[P_h | P_t]`
  defp cons(_list, %Inspect.Opts{limit: 0} = opts),
    do: {{:cons, anno(), @elision, {nil, anno()}}, opts}

  defp cons(list, mode), do: cons_tail(list, mode)

  defp cons_tail([], mode), do: {{nil, anno()}, mode}
  defp cons_tail([_ | _], %Inspect.Opts{limit: 0} = opts), do: {@elision, opts}

  defp cons_tail([head | tail], mode) do
    {head, mode} = abstract(head, spend(mode, 1))
    {tail, mode} = cons_tail(tail, mode)
    {{:cons, anno(), head, tail}, mode}
  end

  defp cons_tail(tail, mode), do: abstract(tail, spend(mode, 1))

  defp decrement(:infinity), do: :infinity
  defp decrement(limit), do: limit - 1

  defp string_element(chars) do
    type = if Enum.all?(chars, &(&1 < 128)), do: :default, else: [:utf8]
    {:bin_element, anno(), {:string, anno(), chars}, :default, type}
  end

  defp bytes(bitstring, limit) when limit == :infinity or byte_size(bitstring) <= limit do
    :erl_parse.abstract(bitstring)
  end

  defp bytes(bitstring, limit) do
    <<head::binary-size(^limit), _rest::bitstring>> = bitstring
    {:bin, anno, elements} = :erl_parse.abstract(head)
    {:bin, anno, elements ++ elision_element(true)}
  end

  defp text(chardata), do: {:text, :unicode.characters_to_list(chardata)}

  defp call(fun, arg) do
    remote = {:remote, anno(), {:atom, anno(), :erlang}, {:atom, anno(), fun}}
    {:call, anno(), remote, [arg]}
  end

  # erl_anno:anno() is opaque to Dialyzer, so a literal 0 would not type-check.
  defp anno, do: :erl_anno.new(0)

  defp printable_prefix(text, limit) do
    {chars, rest} = take_chars(text, limit, [])

    cond do
      not printable?(text, chars) -> :error
      text_end?(text, rest) -> {:ok, chars, false}
      is_integer(limit) and length(chars) == limit -> {:ok, chars, true}
      true -> :error
    end
  end

  defp text_end?(list, rest) when is_list(list), do: rest == []
  defp text_end?(_bitstring, rest), do: rest == ""

  defp take_chars(list, limit, acc) when is_list(list), do: take_list_chars(list, limit, acc)
  defp take_chars(bitstring, limit, acc), do: take_binary_chars(bitstring, limit, acc)

  defp take_list_chars([char | rest], limit, acc) when limit == :infinity or limit > 0,
    do: take_list_chars(rest, decrement(limit), [char | acc])

  defp take_list_chars(rest, _limit, acc), do: {Enum.reverse(acc), rest}

  defp take_binary_chars(<<char::utf8, rest::bitstring>>, limit, acc)
       when limit == :infinity or limit > 0,
       do: take_binary_chars(rest, decrement(limit), [char | acc])

  defp take_binary_chars(rest, _limit, acc), do: {Enum.reverse(acc), rest}

  # ASCII only for lists, so a list of numbers such as [200, 201, 204] is not shown as text.
  defp printable?(list, chars) when is_list(list), do: List.ascii_printable?(chars)
  defp printable?(_bitstring, chars), do: :io_lib.printable_unicode_list(chars)
end
