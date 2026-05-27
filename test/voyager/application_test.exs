defmodule Voyager.ApplicationTest do
  use ExUnit.Case, async: true

  test "Voyager.Inspector.TaskSupervisor is running" do
    pid = Process.whereis(Voyager.TaskSupervisor)
    assert is_pid(pid)
    assert Process.alive?(pid)
  end
end
