defmodule Voyager.Services.OpenSSH.ExecutorTest do
  use ExUnit.Case, async: false

  alias Voyager.Services.OpenSSH.Executor

  setup do
    tmp = Path.join(System.tmp_dir!(), "voyager_exec_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:voyager, :known_hosts_path, Path.join(tmp, "known_hosts"))

    on_exit(fn ->
      Application.delete_env(:voyager, :known_hosts_path)
      File.rm_rf!(tmp)
    end)

    :ok
  end

  describe "exec/6" do
    test "returns :exec_failed for an unreachable host" do
      assert {:error, {:exec_failed, _code, output}} =
               Executor.exec("nobody", "127.0.0.1", 1, :agent, "echo hi")

      assert is_binary(output)
    end

    test "ssh! finds the system ssh binary" do
      assert is_binary(Executor.ssh!())
      assert String.ends_with?(Executor.ssh!(), "ssh")
    end
  end
end
