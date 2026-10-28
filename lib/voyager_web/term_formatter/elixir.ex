defmodule VoyagerWeb.TermFormatter.Elixir do
  @moduledoc false

  alias Voyager.Pid
  alias VoyagerWeb.TermFormatter

  @spec inspect(term(), keyword()) :: String.t()
  def inspect(term, opts \\ []),
    do: Kernel.inspect(term, Keyword.put_new(opts, :inspect_fun, &inspect_fun/2))

  @doc """
  `term` uncut, with structs as maps and pids, refs, ports and anonymous
  functions as expressions that rebuild them, so it pastes into IEx. Wraps at
  `:width`.
  """
  @spec copy_string(term(), keyword()) :: String.t()
  def copy_string(term, opts \\ []) do
    Kernel.inspect(
      term,
      Keyword.take(opts, [:width]) ++
        [
          limit: :infinity,
          printable_limit: :infinity,
          pretty: true,
          structs: false,
          inspect_fun: &copy_inspect/2
        ]
    )
  end

  defp inspect_fun(pid, opts) when is_pid(pid), do: Pid.inspect_fun(pid, opts)

  defp inspect_fun(struct, opts) when is_struct(struct) do
    Inspect.inspect(struct, opts)
  rescue
    _error -> Inspect.Any.inspect(struct, opts)
  end

  defp inspect_fun(term, opts), do: Inspect.inspect(term, opts)

  # Pids and other `#Name<...>` forms have no literal syntax. Rewriting the flattened output
  # instead would reach inside string literals and break any binary that reads like a pid.
  defp copy_inspect(id, _opts) when is_pid(id) or is_reference(id) or is_port(id) do
    {fun, arg} = TermFormatter.term_to_local_term(id)
    ":erlang.#{fun}(#{Kernel.inspect(arg, limit: :infinity)})"
  end

  defp copy_inspect(fun, _opts) when is_function(fun) do
    case Kernel.inspect(fun) do
      "#" <> _ = text -> Kernel.inspect(text)
      text -> text
    end
  end

  defp copy_inspect(term, opts), do: Inspect.inspect(term, opts)
end
