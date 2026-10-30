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

  describe "parse/1 hosts" do
    test "lists a host block without settings" do
      assert Config.parse("Host prod\n").hosts == [
               %{
                 alias: "prod",
                 host_name: nil,
                 user: nil,
                 port: nil,
                 identity_files: [],
                 identity_agent: nil
               }
             ]
    end

    test "lists one host per concrete pattern, in file order" do
      contents = """
      Host prod staging
      Host *.internal !legacy db?
      Host prod
      """

      assert contents |> Config.parse() |> aliases() == ["prod", "staging"]
    end

    test "does not list lines before the first Host as a host" do
      assert Config.parse("User root\nPort 22\n").hosts == []
    end

    test "skips a Match block and reports it" do
      contents = """
      Match host *.corp
        User corp
      Host prod
      """

      assert contents |> Config.parse() |> aliases() == ["prod"]
      assert Config.parse(contents).unsupported == [%{keyword: "match", type: :block}]
    end
  end

  describe "parse/1 values" do
    test "reads a host's own settings" do
      contents = """
      Host prod
        HostName 203.0.113.10
        User deploy
        Port 2222
        IdentityFile ~/.ssh/id_prod
        IdentityAgent "~/My Agent/agent.sock"
      """

      assert Config.parse(contents).hosts == [
               %{
                 alias: "prod",
                 host_name: "203.0.113.10",
                 user: "deploy",
                 port: 2222,
                 identity_files: [Path.expand("~/.ssh/id_prod")],
                 identity_agent: Path.expand("~/My Agent/agent.sock")
               }
             ]
    end

    test "splits arguments like OpenSSH's argv_split test vectors" do
      for {args, expected} <- [
            {~S(leamas), ["leamas"]},
            {~S(smiley leamas), ["smiley", "leamas"]},
            {~S("smiley"), ["smiley"]},
            {~S(leamas " smiley "), ["leamas", " smiley "]},
            {~S("smiley leamas"), ["smiley leamas"]},
            {~S(smiley" leamas" liz), ["smiley leamas", "liz"]},
            {~S(\"smiley\'), [~S("smiley')]},
            {~S('\'smiley\"'), [~S('smiley")]},
            {~S(smiley\'s leamas\'), ["smiley's", "leamas'"]},
            {~S(leamas\\smiley), [~S(leamas\smiley)]},
            {~S(leamas\\ \\smiley), ["leamas\\", ~S(\smiley)]},
            {~S(smiley\ leamas), ["smiley leamas"]},
            {~S('smiley\ leamas'), [~S(smiley\ leamas)]},
            {~S("smiley\ leamas"), [~S(smiley\ leamas)]},
            {~S(# gold), []},
            {~S(leamas#gold), ["leamas#gold"]},
            {~S("leamas # gold"), ["leamas # gold"]},
            {~S("leamas"#gold), ["leamas#gold"]}
          ] do
        assert "Host #{args}\n" |> Config.parse() |> aliases() == expected, args
      end
    end

    test "fills unset values from the top level and Host *, keeping the first value" do
      contents = """
      User root

      Host prod
        User deploy
        HostName prod.example.com

      Host *
        User nobody
        Port 2222
      """

      assert %{user: "root", host_name: "prod.example.com", port: 2222} = host(contents, "prod")
    end

    test "matches Host patterns against the alias, not HostName" do
      contents = """
      Host prod
        HostName 10.0.0.5

      Host 10.0.*
        User internal
      """

      assert host(contents, "prod").user == nil
    end

    test "matches * and ? wildcards" do
      contents = """
      Host db1 api.internal db10

      Host db? *.internal
        User ops
      """

      assert host(contents, "db1").user == "ops"
      assert host(contents, "api.internal").user == "ops"
      assert host(contents, "db10").user == nil
    end

    test "skips a block whose negated pattern matches" do
      contents = """
      Host prod staging

      Host * !staging
        User deploy
      """

      assert host(contents, "prod").user == "deploy"
      assert host(contents, "staging").user == nil
    end

    test "accumulates IdentityFile in order without duplicates" do
      contents = """
      Host prod
        IdentityFile ~/.ssh/a

      Host *
        IdentityFile ~/.ssh/b
        IdentityFile ~/.ssh/a
      """

      assert host(contents, "prod").identity_files == [
               Path.expand("~/.ssh/a"),
               Path.expand("~/.ssh/b")
             ]
    end

    test "reads IdentityAgent none and SSH_AUTH_SOCK" do
      contents = """
      Host off
        IdentityAgent none

      Host env
        IdentityAgent SSH_AUTH_SOCK

      Host custom

      Host *
        IdentityAgent ~/agent.sock
      """

      assert host(contents, "off").identity_agent == :none
      assert host(contents, "env").identity_agent == nil
      assert host(contents, "custom").identity_agent == Path.expand("~/agent.sock")
    end

    test "reports a Port outside 1..65535 or with trailing text" do
      for port <- ["abc", "0", "70000", "22x"] do
        result = Config.parse("Host prod\n  Port #{port}\n")

        assert result.unsupported == [%{keyword: "port", type: :value}], port
        assert [%{port: nil}] = result.hosts
      end
    end

    test "reports a value with a token and keeps the rest of the host" do
      contents = """
      Host prod
        IdentityFile ~/.ssh/%h
        User ${USER}
        HostName prod.example.com
      """

      result = Config.parse(contents)

      assert result.unsupported == [
               %{keyword: "identityfile", type: :value},
               %{keyword: "user", type: :value}
             ]

      assert [%{identity_files: [], user: nil, host_name: "prod.example.com"}] = result.hosts
    end

    test "does not apply the settings under a Host without patterns" do
      contents = """
      Host prod

      Host
        User leaked
      """

      assert host(contents, "prod").user == nil
    end
  end

  describe "parse/1 unsupported" do
    test "reports every other keyword once, in file order, without touching the hosts" do
      contents = """
      Host *
        AddKeysToAgent yes
        UseKeychain yes

      Host prod
        ProxyJump bastion
        HostName 10.0.0.5

      Host staging
        ProxyJump bastion
      """

      result = Config.parse(contents)

      assert result.unsupported == [
               %{keyword: "addkeystoagent", type: :keyword},
               %{keyword: "usekeychain", type: :keyword},
               %{keyword: "proxyjump", type: :keyword}
             ]

      assert [%{alias: "prod", host_name: "10.0.0.5"}, %{alias: "staging"}] = result.hosts
    end

    test "reports a keyword once per type" do
      contents = """
      Host prod
        Port abc
        Port 0
        Match host a
        Match host b
      """

      assert Config.parse(contents).unsupported == [
               %{keyword: "port", type: :value},
               %{keyword: "match", type: :block}
             ]
    end
  end

  describe "parse/1 with Include" do
    test "lists hosts from an included file", %{tmp_dir: tmp_dir} do
      path = write!(tmp_dir, "extra", "Host extra\n")

      assert ~s(Include "#{path}"\nHost prod\n) |> Config.parse() |> aliases() == [
               "extra",
               "prod"
             ]
    end

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

  defp aliases(result), do: Enum.map(result.hosts, & &1.alias)

  defp host(contents, name), do: Enum.find(Config.parse(contents).hosts, &(&1.alias == name))

  defp write!(dir, name, contents) do
    path = Path.join(dir, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end
end
