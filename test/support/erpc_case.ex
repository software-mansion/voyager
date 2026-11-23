defmodule Voyager.ErpcCase do
  @moduledoc """
  Test case for tests against a real remote node: starts distribution and a `:peer` node, and
  puts it in the context as `:node`. `Voyager.ErpcMock` stays the configured erpc impl.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # async: false because starting distribution renames the local node for the whole VM;
      # sync modules run after the async ones that assert on nonode.
      use ExUnit.Case, async: false
    end
  end

  setup do
    unless Node.alive?() do
      {_output, 0} = System.cmd("epmd", ["-daemon"])

      {:ok, _pid} =
        :net_kernel.start(:"voyager_test_#{System.unique_integer([:positive])}", %{
          name_domain: :shortnames
        })

      on_exit(fn -> :net_kernel.stop() end)
    end

    {:ok, peer, node} =
      :peer.start(%{name: :"voyager_peer_#{System.unique_integer([:positive])}"})

    on_exit(fn -> :peer.stop(peer) end)

    %{node: node}
  end
end
