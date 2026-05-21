defmodule VoyagerWeb.SupervisionTreeLive.DiffTest do
  use ExUnit.Case, async: true

  alias VoyagerWeb.SupervisionTreeLive.Diff

  defp tree(root_pid, worker_pid) do
    %{
      voyager_fixture: %{
        pid: root_pid,
        name: :voyager_fixture,
        type: :app,
        modules: [],
        info: nil,
        has_children?: true,
        children: [
          %{
            pid: root_pid,
            name: :voyager_fixture,
            type: :supervisor,
            modules: [],
            info: %{memory: 100, message_queue_len: 0},
            has_children?: true,
            children: [
              %{
                pid: worker_pid,
                name: :worker_one,
                type: :worker,
                modules: [],
                info: %{memory: 1000, message_queue_len: 0},
                has_children?: false,
                children: :not_loaded
              }
            ]
          }
        ]
      }
    }
  end

  describe "flatten/1" do
    test "produces stable keys for app wrappers and real pids" do
      root = self()
      worker = spawn(fn -> :ok end)

      flat = Diff.flatten(tree(root, worker))

      root_key = root |> :erlang.pid_to_list() |> List.to_string()
      worker_key = worker |> :erlang.pid_to_list() |> List.to_string()

      assert Map.has_key?(flat, "app:voyager_fixture")
      assert Map.has_key?(flat, root_key)
      assert Map.has_key?(flat, worker_key)

      app = flat["app:voyager_fixture"]
      assert app.parent_key == nil
      assert app.type == :app
      assert app.children_keys == [root_key]

      sup = flat[root_key]
      assert sup.parent_key == "app:voyager_fixture"
      assert sup.type == :supervisor
      assert sup.children_keys == [worker_key]

      leaf = flat[worker_key]
      assert leaf.parent_key == root_key
      assert leaf.children_keys == :not_loaded
    end

    test "produces stable keys for ghost children (pid: nil)" do
      ghost_tree = %{
        my_app: %{
          pid: self(),
          name: :my_app,
          type: :app,
          modules: [],
          info: nil,
          has_children?: true,
          children: [
            %{
              pid: nil,
              name: {SomeMod, 0},
              type: :worker,
              modules: [],
              info: nil,
              has_children?: false,
              children: :not_loaded
            }
          ]
        }
      }

      flat = Diff.flatten(ghost_tree)

      ghost_key =
        Map.keys(flat) |> Enum.find(&String.contains?(&1, "::ghost::"))

      assert ghost_key
      assert flat[ghost_key].parent_key == "app:my_app"
    end

    test "returns an empty map for nil input" do
      assert Diff.flatten(nil) == %{}
    end
  end

  describe "diff/2" do
    test "returns empty added/removed/updated for identical inputs" do
      root = self()
      worker = spawn(fn -> :ok end)
      flat = Diff.flatten(tree(root, worker))

      assert %{added: added, removed: [], updated: updated} = Diff.diff(flat, flat)
      assert added == %{}
      assert updated == %{}
    end

    test "restarted pid appears as one remove + one add" do
      root = self()
      worker_a = spawn(fn -> :ok end)
      worker_b = spawn(fn -> :ok end)

      prev = Diff.flatten(tree(root, worker_a))
      curr = Diff.flatten(tree(root, worker_b))

      result = Diff.diff(prev, curr)
      key_a = worker_a |> :erlang.pid_to_list() |> List.to_string()
      key_b = worker_b |> :erlang.pid_to_list() |> List.to_string()

      assert key_a in result.removed
      assert Map.has_key?(result.added, key_b)
      # The supervisor's children_keys changed too, so it shows up in updated.
      root_key = root |> :erlang.pid_to_list() |> List.to_string()
      assert Map.has_key?(result.updated, root_key)
      assert result.updated[root_key].children_keys == [key_b]
    end
  end
end
