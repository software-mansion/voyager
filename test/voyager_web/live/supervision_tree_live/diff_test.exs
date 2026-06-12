defmodule VoyagerWeb.SupervisionTreeLive.DiffTest do
  use ExUnit.Case, async: true

  alias Voyager.Services.SupervisionTree.TreeNode
  alias VoyagerWeb.SupervisionTreeLive.Diff

  # The flat key for a pid, matching the walker's `id_key/1`.
  defp key(pid), do: pid |> :erlang.pid_to_list() |> List.to_string()

  defp node_entry(key, parent_key, name, type, has_children, child_count, info, children_keys) do
    %TreeNode{
      key: key,
      parent_key: parent_key,
      name: name,
      type: type,
      has_children: has_children,
      child_count: child_count,
      info: info,
      children_keys: children_keys
    }
  end

  # A minimal flat node map of the same shape the walker emits:
  # app:voyager_fixture -> root supervisor -> one worker.
  defp flat(root_pid, worker_pid, opts \\ []) do
    worker_info = Keyword.get(opts, :worker_info, %{memory: 1000, message_queue_len: 0})

    app_key = "app:voyager_fixture"
    root_key = key(root_pid)
    worker_key = key(worker_pid)

    %{
      app_key => node_entry(app_key, nil, :voyager_fixture, :app, true, 1, nil, [root_key]),
      root_key =>
        node_entry(
          root_key,
          app_key,
          :voyager_fixture,
          :supervisor,
          true,
          1,
          %{memory: 100, message_queue_len: 0},
          [worker_key]
        ),
      worker_key =>
        node_entry(worker_key, root_key, :worker_one, :worker, false, 0, worker_info, :not_loaded)
    }
  end

  describe "diff/2" do
    test "returns empty added/removed/updated for identical inputs" do
      root = self()
      worker = spawn(fn -> :ok end)
      flat = flat(root, worker)

      assert %{added: added, removed: [], updated: updated} = Diff.diff(flat, flat)
      assert added == %{}
      assert updated == %{}
    end

    test "info-only changes produce a patch whose only key is :info" do
      root = self()
      worker = spawn(fn -> :ok end)

      prev = flat(root, worker)
      curr = flat(root, worker, worker_info: %{memory: 2048, message_queue_len: 3})

      worker_key = key(worker)

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

      prev = flat(root, worker_a)
      curr = flat(root, worker_b)

      result = Diff.diff(prev, curr)
      key_a = key(worker_a)
      key_b = key(worker_b)

      assert key_a in result.removed
      assert Map.has_key?(result.added, key_b)
      # The supervisor's children_keys changed too, so it shows up in updated.
      root_key = key(root)
      assert Map.has_key?(result.updated, root_key)
      assert result.updated[root_key].children_keys == [key_b]
    end
  end
end
