Code.require_file("ets_demo.exs", __DIR__)
Code.require_file("supervision_tree_demo.exs", __DIR__)

defmodule VoyagerDemo do
  def start do
    {:ok, _pid} = Agent.start(&EtsDemo.seed/0, name: EtsDemo)
    {:ok, _started} = SupervisionTreeDemo.start()
    :ok
  end
end
