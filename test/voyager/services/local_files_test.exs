defmodule Voyager.Services.LocalFilesTest do
  use ExUnit.Case, async: true

  alias Voyager.Services.LocalFiles

  @moduletag :tmp_dir

  @max_config_bytes 1_048_576

  describe "read_config/1" do
    test "returns the contents of a regular file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "config")
      File.write!(path, "Host demo\n")

      assert LocalFiles.read_config(path) == {:ok, "Host demo\n"}
    end

    test "refuses a file that is not a regular file", %{tmp_dir: tmp_dir} do
      assert LocalFiles.read_config(tmp_dir) ==
               {:error, {:read_failed, {tmp_dir, :not_regular_file}}}
    end

    test "refuses a group- or world-writable file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "config")
      File.write!(path, "Host demo\n")

      for mode <- [0o620, 0o602] do
        File.chmod!(path, mode)

        assert LocalFiles.read_config(path) ==
                 {:error, {:read_failed, {path, :bad_permissions}}},
               inspect(mode, base: :octal)
      end
    end

    test "accepts a file at the size cap and refuses one byte more", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "config")

      File.write!(path, :binary.copy("#", @max_config_bytes))
      assert {:ok, contents} = LocalFiles.read_config(path)
      assert byte_size(contents) == @max_config_bytes

      File.write!(path, :binary.copy("#", @max_config_bytes + 1))
      assert LocalFiles.read_config(path) == {:error, {:read_failed, {path, :too_large}}}
    end

    test "tags a missing file with the expanded path", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "missing")

      assert LocalFiles.read_config(Path.relative_to_cwd(path)) ==
               {:error, {:read_failed, {path, :enoent}}}
    end
  end

  describe "read/1" do
    test "returns the contents of a file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "config")
      File.write!(path, "Host demo\n")

      assert LocalFiles.read(path) == {:ok, "Host demo\n"}
    end

    test "tags a failure with the expanded path", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "missing")

      assert LocalFiles.read(Path.relative_to_cwd(path)) ==
               {:error, {:read_failed, {path, :enoent}}}
    end
  end

  describe "write/3" do
    test "creates missing parent directories", %{tmp_dir: tmp_dir} do
      path = Path.join([tmp_dir, "voyager", "ssh", "known_hosts"])

      assert LocalFiles.write(path, "host key\n") == :ok
      assert File.read!(path) == "host key\n"
    end

    test "appends when asked to", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "known_hosts")

      assert LocalFiles.write(path, "first\n") == :ok
      assert LocalFiles.write(path, "second\n", [:append]) == :ok
      assert File.read!(path) == "first\nsecond\n"
    end

    test "tags a failure with the expanded path", %{tmp_dir: tmp_dir} do
      parent = Path.join(tmp_dir, "file")
      path = Path.join(parent, "known_hosts")
      File.write!(parent, "")

      assert {:error, {:write_failed, {^path, reason}}} = LocalFiles.write(path, "host key\n")
      assert reason in [:enotdir, :eexist]
    end
  end
end
