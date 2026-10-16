defmodule VoyagerWeb.TermFormatter do
  @moduledoc """
  Renders any term as text in Elixir or Erlang syntax.

  Never raises: a struct whose `Inspect` implementation fails on a remote
  value is shown as a plain struct instead of an `Inspect.Error` report. Pids
  follow the PID format setting in both syntaxes.
  """

  alias Voyager.Pid
  alias Voyager.Services.TermSyntax
  alias VoyagerWeb.TermFormatter.Erlang

  @doc """
  Renders `term` as text.

  Accepts `:syntax` (defaults to `Voyager.Services.TermSyntax.current/0`) and the
  `Inspect.Opts` fields both syntaxes honour: `:limit`, `:printable_limit`,
  `:pretty` and `:width`. The Elixir syntax takes any other `inspect/2` option.
  """
  @spec inspect(term(), keyword()) :: String.t()
  def inspect(term, opts \\ []) do
    {syntax, opts} = Keyword.pop_lazy(opts, :syntax, &TermSyntax.current/0)

    case syntax do
      :elixir -> Kernel.inspect(term, Keyword.put_new(opts, :inspect_fun, &inspect_fun/2))
      :erlang -> Erlang.inspect(term, opts)
    end
  end

  @doc ~S|Renders an `{module, function, arity}` call target, e.g. `"Enum.map/2"` or `"lists:map/2"`.|
  @spec format_mfa(term(), keyword()) :: String.t()
  def format_mfa(mfa, opts \\ [])

  def format_mfa({mod, fun, arity} = mfa, opts)
      when is_atom(mod) and is_atom(fun) and is_integer(arity) and arity >= 0 do
    case Keyword.get_lazy(opts, :syntax, &TermSyntax.current/0) do
      :elixir -> Exception.format_mfa(mod, fun, arity)
      :erlang -> Erlang.format_mfa(mfa)
    end
  end

  def format_mfa(other, opts), do: __MODULE__.inspect(other, opts)

  @doc """
  The `erlang` BIF and its argument that rebuild `id` in a shell on the
  connected node, which numbers its own pids, refs and ports `0`.
  """
  @spec identifier(pid() | reference() | port()) :: {atom(), String.t()}
  def identifier(pid) when is_pid(pid), do: {:list_to_pid, localize(:erlang.pid_to_list(pid))}

  def identifier(ref) when is_reference(ref),
    do: {:list_to_ref, localize(:erlang.ref_to_list(ref))}

  def identifier(port) when is_port(port),
    do: {:list_to_port, localize(:erlang.port_to_list(port))}

  defp localize(chars) do
    text = List.to_string(chars)

    case Pid.cached_node_id() do
      nil -> text
      id -> String.replace(text, "<#{id}.", "<0.", global: false)
    end
  end

  defp inspect_fun(struct, opts) when is_struct(struct) do
    Inspect.inspect(struct, opts)
  rescue
    _error -> Inspect.Any.inspect(struct, opts)
  end

  defp inspect_fun(term, opts), do: Pid.inspect_fun(term, opts)
end
