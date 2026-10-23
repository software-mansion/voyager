defmodule VoyagerWeb.TermFormatter.Erlang do
  @moduledoc """
  Prints terms in Erlang syntax with `erl_pp`, from an abstract form built
  here, so the output never depends on the VM's `+pc` flag.
  """

  alias Voyager.Pid
  alias VoyagerWeb.TermFormatter

  @single_line 1_000_000_000
  @elision {:text, ~c"..."}

  @spec inspect(term(), keyword()) :: String.t()
  def inspect(term, opts \\ []) do
    opts = Inspect.Opts.new(opts)
    term |> abstract(opts) |> print(line_length(opts))
  end

  @doc """
  `term` uncut, with pids, refs and ports as calls that rebuild them, so it
  pastes into `erl`. Wraps at `:width`.
  """
  @spec copy_string(term(), keyword()) :: String.t()
  def copy_string(term, opts \\ []) do
    opts = Inspect.Opts.new([pretty: true] ++ opts)
    term |> abstract(:copy) |> print(line_length(opts))
  end

  @spec format_mfa({module(), atom(), arity()}) :: String.t()
  def format_mfa({mod, fun, arity}), do: "#{atom(mod)}:#{atom(fun)}/#{arity}"

  @spec atom(atom()) :: String.t()
  def atom(atom), do: atom |> :io_lib.write_atom() |> IO.chardata_to_string()

  @doc "Whether the first `limit` elements of `list` read as a string; the rest is not walked."
  @spec printable_list?(list(), non_neg_integer() | :infinity) :: boolean()
  def printable_list?(list, limit),
    do: match?({:ok, _chars, _more?}, printable_prefix(list, limit))

  defp print(form, line_length) do
    form
    |> :erl_pp.expr(hook: &text_hook/4, encoding: :unicode, linewidth: line_length)
    |> IO.chardata_to_string()
  end

  defp line_length(%Inspect.Opts{pretty: true, width: width}) when is_integer(width), do: width
  defp line_length(_opts), do: @single_line

  defp abstract(id, :copy) when is_pid(id) or is_reference(id) or is_port(id) do
    {fun, arg} = TermFormatter.identifier(id)
    call(fun, :erl_parse.abstract(arg))
  end

  defp abstract(pid, _opts) when is_pid(pid), do: text(Pid.format(pid))
  defp abstract(ref, _opts) when is_reference(ref), do: text(:erlang.ref_to_list(ref))
  defp abstract(port, _opts) when is_port(port), do: text(:erlang.port_to_list(port))

  defp abstract(fun, mode) when is_function(fun) do
    case :erlang.fun_info(fun, :type) do
      {:type, :external} ->
        :erl_parse.abstract(fun)

      {:type, :local} when mode == :copy ->
        {:string, anno(), :erlang.fun_to_list(fun)}

      {:type, :local} ->
        text(:erlang.fun_to_list(fun))
    end
  end

  defp abstract(tuple, mode) when is_tuple(tuple) do
    {items, more?} = tuple |> Tuple.to_list() |> cut(limit(mode))
    {:tuple, anno(), Enum.map(items, &abstract(&1, mode)) ++ elision(more?)}
  end

  defp abstract(map, mode) when is_map(map) do
    {pairs, more?} = map |> :maps.to_list() |> Enum.sort() |> cut(limit(mode))

    fields =
      for {key, value} <- pairs do
        {:map_field_assoc, anno(), abstract(key, mode), abstract(value, mode)}
      end

    elided = for elision <- elision(more?), do: {:map_field_assoc, anno(), elision, elision}
    {:map, anno(), fields ++ elided}
  end

  defp abstract([_ | _] = list, mode) do
    case printable_prefix(list, printable_limit(mode)) do
      {:ok, chars, more?} -> string(chars, more?)
      :error -> cons(list, limit(mode), mode)
    end
  end

  defp abstract(bitstring, mode) when is_bitstring(bitstring) and bitstring != "" do
    case printable_prefix(bitstring, printable_limit(mode)) do
      {:ok, chars, more?} -> {:bin, anno(), [string_element(chars) | elision_element(more?)]}
      :error -> bytes(bitstring, limit(mode))
    end
  end

  defp abstract(other, _mode), do: :erl_parse.abstract(other)

  # Each nested collection gets its own :limit; the agent's term budget bounds the total.
  defp limit(:copy), do: :infinity
  defp limit(%Inspect.Opts{limit: limit}), do: limit

  defp printable_limit(:copy), do: :infinity
  defp printable_limit(%Inspect.Opts{printable_limit: limit}), do: limit

  defp cut(items, :infinity), do: {items, false}

  defp cut(items, limit) do
    {kept, rest} = Enum.split(items, limit)
    {kept, rest != []}
  end

  defp elision(true), do: [@elision]
  defp elision(false), do: []

  defp elision_element(more?) do
    for elision <- elision(more?), do: {:bin_element, anno(), elision, :default, :default}
  end

  defp string(chars, false), do: {:string, anno(), chars}
  defp string(chars, true), do: {:op, anno(), :++, {:string, anno(), chars}, @elision}

  defp cons(_list, 0, _mode), do: {:cons, anno(), @elision, {nil, anno()}}
  defp cons(list, limit, mode), do: cons_tail(list, limit, mode)

  defp cons_tail([], _limit, _mode), do: {nil, anno()}
  defp cons_tail([_ | _], 0, _mode), do: @elision

  defp cons_tail([head | tail], limit, mode) do
    {:cons, anno(), abstract(head, mode), cons_tail(tail, decrement(limit), mode)}
  end

  defp cons_tail(tail, _limit, mode), do: abstract(tail, mode)

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

  defp printable_prefix(text, limit) do
    {chars, rest} = take_chars(text, limit, [])

    cond do
      not :io_lib.printable_unicode_list(chars) -> :error
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

  defp text(chardata), do: {:text, :unicode.characters_to_list(chardata)}

  defp text_hook({:text, chars}, _indent, _precedence, _options), do: chars

  defp call(fun, arg) do
    remote = {:remote, anno(), {:atom, anno(), :erlang}, {:atom, anno(), fun}}
    {:call, anno(), remote, [arg]}
  end

  # erl_anno:anno() is opaque to Dialyzer, so a literal 0 would not type-check.
  defp anno, do: :erl_anno.new(0)
end
