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
  connected node: `list_to_*` from the local form for that node's own pids,
  refs and ports, which it numbers `0`, and `binary_to_term` for any other
  node's, whose `<N.X.Y>` form would name a different node there.
  """
  @spec identifier(pid() | reference() | port()) :: {atom(), charlist() | binary()}
  def identifier(id) when is_pid(id) or is_reference(id) or is_port(id) do
    text = id |> id_to_list() |> List.to_string()
    local = Pid.localize(text)

    if local == text and Pid.cached_node_id() != nil do
      {:binary_to_term, :erlang.term_to_binary(id)}
    else
      {list_to_id(id), String.to_charlist(local)}
    end
  end

  defp id_to_list(pid) when is_pid(pid), do: :erlang.pid_to_list(pid)
  defp id_to_list(ref) when is_reference(ref), do: :erlang.ref_to_list(ref)
  defp id_to_list(port) when is_port(port), do: :erlang.port_to_list(port)

  defp list_to_id(pid) when is_pid(pid), do: :list_to_pid
  defp list_to_id(ref) when is_reference(ref), do: :list_to_ref
  defp list_to_id(port) when is_port(port), do: :list_to_port

  defp inspect_fun(pid, opts) when is_pid(pid), do: Pid.inspect_fun(pid, opts)

  defp inspect_fun(struct, opts) when is_struct(struct) do
    Inspect.inspect(struct, opts)
  rescue
    _error -> Inspect.Any.inspect(struct, opts)
  end

  defp inspect_fun(term, opts), do: Inspect.inspect(term, opts)
end
