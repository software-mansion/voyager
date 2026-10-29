defmodule Voyager.Services.SSH.ConfigTest do
  use ExUnit.Case, async: true

  alias Voyager.Services.SSH.Config

  @moduletag :tmp_dir

  describe "read/1" do
    test "parses the file at the path", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "config")
      File.write!(path, "")

      assert Config.read(path) == {:ok, %{hosts: [], unsupported: []}}
    end

    test "passes a read failure through", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "missing")

      assert Config.read(path) == {:error, {:read_failed, {path, :enoent}}}
    end
  end
end
