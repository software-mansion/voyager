defmodule VoyagerWeb.SupervisionTreeLive.DiffTest do
  use ExUnit.Case, async: true

  alias VoyagerWeb.SupervisionTreeLive.Diff

  defp tree(root_pid, worker_pid, opts \\ []) do
    worker_info = Keyword.get(opts, :worker_info, %{memory: 1000, message_queue_len: 0})

    %{
      voyager_fixture: %{
        pid: root_pid,
        name: :voyager_fixture,
        type: :app,
        modules: [],
        info: nil,
        has_children?: true,
        child_count: 1,
        children: [
          %{
            pid: root_pid,
            name: :voyager_fixture,
            type: :supervisor,
            modules: [],
            info: %{memory: 100, message_queue_len: 0},
            has_children?: true,
            child_count: 1,
            children: [
              %{
                pid: worker_pid,
                name: :worker_one,
                type: :worker,
                modules: [],
                info: worker_info,
                has_children?: false,
                child_count: 0,
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
      assert leaf.child_count == 0
      assert leaf.info == %{memory: 1000, message_queue_len: 0}

      assert app.child_count == 1
      assert sup.child_count == 1
      assert sup.info == %{memory: 100, message_queue_len: 0}
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
          child_count: 1,
          children: [
            %{
              pid: nil,
              name: {SomeMod, 0},
              type: :worker,
              modules: [],
              info: nil,
              has_children?: false,
              child_count: 0,
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

    test "info-only changes produce a patch whose only key is :info" do
      root = self()
      worker = spawn(fn -> :ok end)

      prev = Diff.flatten(tree(root, worker))

      curr =
        Diff.flatten(tree(root, worker, worker_info: %{memory: 2048, message_queue_len: 3}))

      worker_key = worker |> :erlang.pid_to_list() |> List.to_string()

      result = Diff.diff(prev, curr)

      assert result.added == %{}
      assert result.removed == []
      assert Map.keys(result.updated) == [worker_key]
      assert Map.keys(result.updated[worker_key]) == [:info]
      assert result.updated[worker_key].info == %{memory: 2048, message_queue_len: 3}
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

  describe "flatten/1 with relationships" do
    test "adds rel_nodes as parentless leaves with stable port/reference keys" do
      root = self()
      worker = spawn(fn -> :ok end)
      external = spawn(fn -> :ok end)
      port = Port.open({:spawn, "cat"}, [:binary])
      ref = make_ref()

      result = %{
        tree: tree(root, worker),
        relations: [],
        rel_nodes: [
          %{id: external, name: :ext, type: :worker, info: nil},
          %{id: port, name: inspect(port), type: :port, info: nil},
          %{id: ref, name: inspect(ref), type: :reference, info: nil}
        ]
      }

      flat = Diff.flatten(result)

      external_key = external |> :erlang.pid_to_list() |> List.to_string()
      assert flat[external_key].type == :worker
      assert flat[external_key].parent_key == nil
      assert flat[external_key].children_keys == :not_loaded

      assert flat["port:#{inspect(port)}"].type == :port
      assert flat["ref:#{inspect(ref)}"].type == :reference

      Port.close(port)
    end

    test "a rel_node whose pid is already in the tree does not overwrite the tree node" do
      root = self()
      worker = spawn(fn -> :ok end)

      result = %{
        tree: tree(root, worker),
        relations: [],
        rel_nodes: [%{id: worker, name: :dup, type: :worker, info: nil}]
      }

      flat = Diff.flatten(result)
      worker_key = worker |> :erlang.pid_to_list() |> List.to_string()

      # The richer tree entry wins (keeps its real name + parent).
      assert flat[worker_key].name == :worker_one
      assert flat[worker_key].parent_key != nil
    end
  end

  describe "relations/1 and diff_relations/2" do
    test "relations/1 builds an id-keyed edge map from a walker result" do
      from = self()
      to = spawn(fn -> :ok end)

      result = %{
        tree: %{},
        relations: [%{from: from, to: to, kind: :monitor}],
        rel_nodes: []
      }

      edges = Diff.relations(result)
      from_key = from |> :erlang.pid_to_list() |> List.to_string()
      to_key = to |> :erlang.pid_to_list() |> List.to_string()
      id = "rel:monitor:#{from_key}->#{to_key}"

      assert Map.has_key?(edges, id)
      assert edges[id] == %{id: id, source: from_key, target: to_key, kind: "monitor"}
    end

    test "relations/1 returns an empty map for bare tree input" do
      assert Diff.relations(tree(self(), spawn(fn -> :ok end))) == %{}
    end

    test "diff_relations/2 reports added and removed edges by id" do
      a = self()
      b = spawn(fn -> :ok end)
      c = spawn(fn -> :ok end)

      prev =
        Diff.relations(%{
          relations: [%{from: a, to: b, kind: :link}],
          tree: %{},
          rel_nodes: []
        })

      curr =
        Diff.relations(%{
          relations: [%{from: a, to: c, kind: :link}],
          tree: %{},
          rel_nodes: []
        })

      %{edges_added: added, edges_removed: removed} = Diff.diff_relations(prev, curr)

      [removed_id] = removed
      assert removed_id =~ "rel:link:"
      assert map_size(added) == 1
    end
  end
end
