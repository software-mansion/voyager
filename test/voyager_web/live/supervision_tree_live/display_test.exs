defmodule VoyagerWeb.SupervisionTreeLive.DisplayTest do
  use ExUnit.Case, async: true

  alias Voyager.Services.SupervisionTree.TreeNode
  alias VoyagerWeb.SupervisionTreeLive.Display

  defp pid_text(pid), do: pid |> :erlang.pid_to_list() |> List.to_string()

  test "formats a process node's name, app, pid and calls as terms" do
    node = %TreeNode{
      key: pid_text(self()),
      type: :supervisor,
      app: :my_app,
      pid: self(),
      name: MyApp.Sup,
      info: %{
        registered_name: MyApp.Sup,
        initial_call: {:proc_lib, :init_p, 5},
        current_function: {:gen_server, :loop, 7}
      }
    }

    assert Display.build(node) == %{
             name: "MyApp.Sup",
             app: ":my_app",
             pid: pid_text(self()),
             initial_call: ":proc_lib.init_p/5",
             current_function: ":gen_server.loop/7"
           }
  end

  test "keeps the raw fields next to the display of a ghost child" do
    node = %TreeNode{key: "ghost", type: :worker, name: {Registry.Partition, 0}, info: :dead}

    assert %{"ghost" => %{name: {Registry.Partition, 0}, display: display}} =
             Display.put_all(%{"ghost" => node})

    assert display == %{
             name: "{Registry.Partition, 0}",
             app: nil,
             pid: nil,
             initial_call: nil,
             current_function: nil
           }
  end
end
