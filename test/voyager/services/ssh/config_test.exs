defmodule Voyager.Services.SSH.ConfigTest do
  use ExUnit.Case, async: true

  alias Voyager.Services.SSH.Config

  @moduletag :tmp_dir

  describe "parse/1" do
    test "skips blank lines and comments" do
      assert Config.parse("\n   \n# Host commented\n\t# indented\n") == %{
               hosts: [],
               unsupported: []
             }
    end

    test "reports a keyword without an argument as a bad value" do
      contents = """
      USER
      Port =
      HostName # nothing here
      IdentityFile "~/.ssh/unterminated
      """

      assert Config.parse(contents).unsupported == [
               %{keyword: "user", type: :value},
               %{keyword: "port", type: :value},
               %{keyword: "hostname", type: :value},
               %{keyword: "identityfile", type: :value}
             ]
    end

    test "does not report a keyword with an argument" do
      contents = """
      User=deploy
      IdentityFile "~/My Keys/id"
      IdentityAgent ~/.ssh/a#b
      """

      assert Config.parse(contents).unsupported == []
    end
  end

  describe "parse/1 with Include" do
    test "reads a top-level include", %{tmp_dir: tmp_dir} do
      path = write!(tmp_dir, "extra", "USER\n")

      assert Config.parse(~s(Include "#{path}"\n)).unsupported == [
               %{keyword: "user", type: :value}
             ]
    end

    test "reads every glob match in sorted order", %{tmp_dir: tmp_dir} do
      write!(tmp_dir, "config.d/b", "PORT\n")
      write!(tmp_dir, "config.d/a", "USER\n")

      assert Config.parse(~s(Include "#{tmp_dir}/config.d/*"\n)).unsupported == [
               %{keyword: "user", type: :value},
               %{keyword: "port", type: :value}
             ]
    end

    test "ignores a pattern that matches nothing", %{tmp_dir: tmp_dir} do
      assert Config.parse(~s(Include "#{tmp_dir}/missing/*"\n)).unsupported == []
    end

    test "reports an include inside a block without reading it", %{tmp_dir: tmp_dir} do
      path = write!(tmp_dir, "extra", "USER\n")

      assert Config.parse(~s(Host prod\n  Include "#{path}"\n)).unsupported == [
               %{keyword: "include", type: :block}
             ]
    end

    test "reports an unreadable include", %{tmp_dir: tmp_dir} do
      assert Config.parse(~s(Include "#{tmp_dir}"\n)).unsupported == [
               %{keyword: "include", type: :value}
             ]
    end

    test "reports a token in an include path" do
      assert Config.parse("Include ~/.ssh/%h.conf\n").unsupported == [
               %{keyword: "include", type: :value}
             ]
    end

    test "stops a self-include at the depth limit", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "config")
      File.write!(path, ~s(Include "#{path}"\n))

      assert {:ok, %{unsupported: [%{keyword: "include", type: :value}]}} = Config.read(path)
    end
  end

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

  defp write!(dir, name, contents) do
    path = Path.join(dir, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end
end
