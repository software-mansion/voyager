defmodule Voyager.Erpc do
  @moduledoc """
  Thin seam over Erlang's `:erpc` so remote calls can be mocked in tests.

  The concrete implementation is resolved at call time from application config
  (`config :voyager, :erpc, ...`) and defaults to `Voyager.Erpc.Impl`, which
  delegates straight to `:erpc`.
  """

  @doc """
  Invokes `fun` in `mod` with `args` on `node`, mirroring `:erpc.call/4`.
  """
  @callback call(node(), module(), atom(), [term()]) :: term()

  @doc """
  Returns the configured `Voyager.Erpc` implementation.
  """
  @spec impl() :: module()
  def impl, do: Application.get_env(:voyager, :erpc, __MODULE__.Impl)

  defmodule Impl do
    @moduledoc """
    Default `Voyager.Erpc` implementation that delegates to Erlang's `:erpc`.
    """

    @behaviour Voyager.Erpc

    @impl Voyager.Erpc
    def call(node, mod, fun, args), do: :erpc.call(node, mod, fun, args)
  end
end
