defmodule Voyager.Erpc do
  @moduledoc """
  Thin seam over Erlang's `:erpc` so remote calls can be mocked in tests.

  The concrete implementation is resolved at call time from application config
  (`config :voyager, :erpc, ...`) and defaults to `Voyager.Erpc.Impl`, which
  delegates straight to `:erpc`.
  """

  @default_timeout 5_000
  @fun :"$voyager_fun"

  @type timeout_time :: 0..4_294_967_295 | :infinity | {:abs, integer()}
  @type call_options :: %{timeout: timeout_time(), always_spawn: boolean()}
  @type timeout_or_options :: timeout_time() | call_options()

  @type erpc_error ::
          :timeout
          | :noconnection
          | {:erpc, term()}
          | {:remote_error, term()}
          | {:remote_exception, term()}
          | {:remote_exit, term()}
          | {:remote_throw, term()}
          | {:unknown_error, term()}

  @doc """
  Invokes `fun` in `mod` with `args` on `node`, mirroring `:erpc.call/4`.
  """
  @callback call(node(), module(), atom(), [term()]) :: term()
  @callback call(node(), module(), atom(), [term()], timeout_or_options()) :: term()

  @doc """
  Returns the configured `Voyager.Erpc` implementation.
  """
  @spec impl() :: module()
  def impl, do: Application.get_env(:voyager, :erpc, __MODULE__.Impl)

  @doc """
  Default timeout for `safe_call/4`, matching `:erpc.call/4`.
  """
  @spec default_timeout() :: 5_000
  def default_timeout, do: @default_timeout

  @spec call(node(), module(), atom(), [term()]) :: term()
  def call(node, mod, fun, args), do: impl().call(node, mod, fun, args)

  @spec call(node(), module(), atom(), [term()], timeout_time() | call_options()) :: term()
  def call(node, mod, fun, args, timeout_or_options),
    do: impl().call(node, mod, fun, args, timeout_or_options)

  @doc """
  Maps an `:erpc.call` catch kind/reason into `{:error, reason}`.
  """
  @spec format_error(:error | :exit | :throw, term()) :: {:error, erpc_error()}
  def format_error(:error, {:erpc, :timeout}), do: {:error, :timeout}
  def format_error(:error, {:erpc, :noconnection}), do: {:error, :noconnection}

  def format_error(:error, {:exception, reason, _stack}),
    do: {:error, {:remote_exception, reason}}

  def format_error(:error, {:erpc, _} = reason), do: {:error, reason}
  def format_error(:error, reason), do: {:error, {:remote_error, reason}}
  def format_error(:exit, reason), do: {:error, {:remote_exit, reason}}
  def format_error(:throw, value), do: {:error, {:remote_throw, value}}
  def format_error(_, error), do: {:error, {:unknown_error, error}}

  @doc """
  Like `call/5`, but returns `{:ok, result}` or `{:error, reason}` instead of
  raising. `safe_call/4` uses `default_timeout/0`.
  """
  @spec safe_call(node(), module(), atom(), [term()]) :: {:ok, term()} | {:error, erpc_error()}
  @spec safe_call(node(), module(), atom(), [term()], timeout_time() | call_options()) ::
          {:ok, term()} | {:error, erpc_error()}
  def safe_call(node, mod, fun, args, timeout_or_options \\ default_timeout()) do
    {:ok, call(node, mod, fun, args, timeout_or_options)}
  catch
    kind, reason -> format_error(kind, reason)
  end

  @doc """
  Replaces funs with `{:"$voyager_fun", inspected_text}` and turns every struct
  into a plain map whose `"__struct__"` string key names the module, so no local
  function or protocol implementation can be reached through a term from the
  remote node.
  """
  @spec inert(term()) :: term()
  def inert(term) when is_function(term), do: {@fun, inspect(term)}
  def inert(list) when is_list(list), do: inert_list(list)

  def inert(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&inert/1) |> List.to_tuple()

  def inert(%{__struct__: mod} = struct) when is_atom(mod),
    do: struct |> inert_map() |> Map.delete(:__struct__) |> Map.put("__struct__", inspect(mod))

  def inert(map) when is_map(map), do: inert_map(map)
  def inert(term), do: term

  # :maps keeps protocol dispatch on `__struct__` out of the walk.
  defp inert_map(map),
    do:
      map
      |> :maps.to_list()
      |> Enum.map(fn {k, v} -> {inert(k), inert(v)} end)
      |> :maps.from_list()

  defp inert_list([head | tail]), do: [inert(head) | inert_list(tail)]
  defp inert_list([]), do: []
  defp inert_list(tail), do: inert(tail)

  defmodule Impl do
    @moduledoc """
    Default `Voyager.Erpc` implementation that delegates to Erlang's `:erpc` and
    passes results and exception reasons through `Voyager.Erpc.inert/1`.
    """

    @behaviour Voyager.Erpc

    @impl Voyager.Erpc
    def call(node, mod, fun, args), do: inert_call(fn -> :erpc.call(node, mod, fun, args) end)

    @impl Voyager.Erpc
    def call(node, mod, fun, args, timeout_or_options),
      do: inert_call(fn -> :erpc.call(node, mod, fun, args, timeout_or_options) end)

    defp inert_call(call) do
      Voyager.Erpc.inert(call.())
    catch
      kind, reason -> :erlang.raise(kind, Voyager.Erpc.inert(reason), __STACKTRACE__)
    end
  end
end
