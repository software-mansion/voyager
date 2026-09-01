defmodule Voyager.Erpc do
  @moduledoc """
  Thin seam over Erlang's `:erpc` so remote calls can be mocked in tests.

  The concrete implementation is resolved at call time from application config
  (`config :voyager, :erpc, ...`) and defaults to `Voyager.Erpc.Impl`, which
  delegates straight to `:erpc`.
  """

  @default_timeout 5_000

  @type timeout_time :: 0..4_294_967_295 | :infinity | {:abs, integer()}
  @type call_options :: %{timeout: timeout_time(), always_spawn: boolean()}
  @type timeout_or_options :: timeout_time() | call_options()

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
  Translates a `catch` kind/reason from `call/4`/`call/5` into `{:error, reason}`.

  Prefer `safe_call/4` (or `/5` with an explicit timeout) at call sites. Use
  `format_error/2` when a `catch` is already in hand (parallel tasks, custom
  wrappers).
  """
  @spec format_error(:error | :exit | :throw, term()) :: {:error, term()}
  def format_error(:error, {:erpc, :timeout}), do: {:error, :timeout}
  def format_error(:error, {:erpc, :noconnection}), do: {:error, :noconnection}

  def format_error(:error, {:exception, reason, _stack}),
    do: {:error, {:remote_exception, reason}}

  def format_error(:error, reason), do: {:error, reason}
  def format_error(:exit, reason), do: {:error, {:remote_exit, reason}}
  def format_error(:throw, value), do: {:error, {:remote_throw, value}}

  @doc """
  Like `call/5`, but returns `{:ok, result}` or `{:error, reason}` instead of
  raising. `safe_call/4` uses `default_timeout/0`.
  """
  @spec safe_call(node(), module(), atom(), [term()]) :: {:ok, term()} | {:error, term()}
  @spec safe_call(node(), module(), atom(), [term()], timeout_time() | call_options()) ::
          {:ok, term()} | {:error, term()}
  def safe_call(node, mod, fun, args, timeout_or_options \\ default_timeout()) do
    {:ok, call(node, mod, fun, args, timeout_or_options)}
  catch
    kind, reason -> format_error(kind, reason)
  end

  defmodule Impl do
    @moduledoc """
    Default `Voyager.Erpc` implementation that delegates to Erlang's `:erpc`.
    """

    @behaviour Voyager.Erpc

    @impl Voyager.Erpc
    def call(node, mod, fun, args), do: :erpc.call(node, mod, fun, args)

    @impl Voyager.Erpc
    def call(node, mod, fun, args, timeout_or_options),
      do: :erpc.call(node, mod, fun, args, timeout_or_options)
  end
end
