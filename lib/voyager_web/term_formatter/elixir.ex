defmodule VoyagerWeb.TermFormatter.Elixir do
  @moduledoc """
  Prints terms in Elixir syntax with `inspect/2`.

  With `round_trip: true` nothing is cut, structs print as maps and pids, refs,
  ports and anonymous functions become expressions that rebuild them, so the
  output pastes into IEx.
  """

  alias Voyager.Pid
  alias VoyagerWeb.TermFormatter

  @spec inspect(term(), keyword()) :: String.t()
  def inspect(term, opts \\ []) do
    {round_trip?, opts} = Keyword.pop(opts, :round_trip, false)

    opts =
      if round_trip? do
        Keyword.merge(opts,
          limit: :infinity,
          printable_limit: :infinity,
          structs: false,
          custom_options: [sort_maps: true],
          inspect_fun: &copy_inspect/2
        )
      else
        Keyword.put_new(opts, :inspect_fun, &inspect_fun/2)
      end

    Kernel.inspect(term, opts)
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
    {fun, arg} = TermFormatter.identifier(id)
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
