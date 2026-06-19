defmodule Voyager.Erpc do
  @moduledoc """
  Thin seam over Erlang's `:erpc` so remote calls can be mocked in tests.

  The concrete implementation is resolved at call time from application config
  (`config :voyager, :erpc, ...`) and defaults to `Voyager.Erpc.Impl`, which
  delegates straight to `:erpc`.
  """

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

  @spec call(node(), module(), atom(), [term()]) :: term()
  def call(node, mod, fun, args), do: impl().call(node, mod, fun, args)

  @spec call(node(), module(), atom(), [term()], timeout_time() | call_options()) :: term()
  def call(node, mod, fun, args, timeout_or_options),
    do: impl().call(node, mod, fun, args, timeout_or_options)

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
