defmodule VoyagerWeb.TermFormatter do
  @moduledoc """
  Renders any term as text in Elixir or Erlang syntax.

  Never raises: a struct whose `Inspect` implementation fails on a remote
  value is shown as a plain struct instead of an `Inspect.Error` report. Pids
  follow the PID format setting in both syntaxes.
  """

  alias Voyager.Services.TermSyntax
  alias VoyagerWeb.TermFormatter.Elixir, as: ElixirFormatter
  alias VoyagerWeb.TermFormatter.Erlang, as: ErlangFormatter

  @callback inspect(term(), keyword()) :: String.t()
  @callback copy_string(term(), keyword()) :: String.t()
  @callback format_mfa({module(), atom(), arity()}) :: String.t()
  @callback printable_list?(list(), keyword()) :: boolean()

  @doc """
  Accepts `:syntax` (defaults to `Voyager.Services.TermSyntax.current/0`) and the
  `Inspect.Opts` fields both syntaxes honour: `:limit`, `:printable_limit`,
  `:pretty` and `:width`. The Elixir syntax takes any other `inspect/2` option.
  """
  @spec inspect(term(), keyword()) :: String.t()
  def inspect(term, opts \\ []) do
    {formatter, opts} = pop_formatter(opts)
    formatter.inspect(term, opts)
  end

  @doc """
  Renders `term` uncut as text that pastes back into IEx or the Erlang shell.
  Accepts `:syntax` and `:width`.
  """
  @spec copy_string(term(), keyword()) :: String.t()
  def copy_string(term, opts \\ []) do
    {formatter, opts} = pop_formatter(opts)
    formatter.copy_string(term, opts)
  end

  @doc """
  Whether `list` prints as text. Accepts `:syntax` and `:printable_limit`
  """
  @spec printable_list?(list(), keyword()) :: boolean()
  def printable_list?(list, opts \\ []) do
    {formatter, opts} = pop_formatter(opts)
    formatter.printable_list?(list, opts)
  end

  @doc ~S|Renders an `{module, function, arity}` call target, e.g. `"Enum.map/2"` or `"lists:map/2"`.|
  @spec format_mfa(term(), keyword()) :: String.t()
  def format_mfa(mfa, opts \\ [])

  def format_mfa({mod, fun, arity} = mfa, opts)
      when is_atom(mod) and is_atom(fun) and is_integer(arity) and arity >= 0 do
    {formatter, _opts} = pop_formatter(opts)
    formatter.format_mfa(mfa)
  end

  def format_mfa(other, opts), do: __MODULE__.inspect(other, opts)

  @doc """
  The `erlang` BIF and argument that rebuild `id` in a shell on any node. The
  binary carries the owning node and its creation, which `<N.X.Y>` text does
  not: `N` is numbered per node, and a restarted node reuses `X.Y`.
  """
  @spec term_to_local_term(pid() | reference() | port()) :: {:binary_to_term, binary()}
  def term_to_local_term(id) when is_pid(id) or is_reference(id) or is_port(id),
    do: {:binary_to_term, :erlang.term_to_binary(id)}

  defp pop_formatter(opts) do
    {syntax, opts} = Keyword.pop_lazy(opts, :syntax, &TermSyntax.current/0)
    {formatter(syntax), opts}
  end

  defp formatter(:elixir), do: ElixirFormatter
  defp formatter(:erlang), do: ErlangFormatter
end
