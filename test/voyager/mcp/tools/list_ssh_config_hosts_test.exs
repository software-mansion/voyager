defmodule Voyager.MCP.Tools.ListSshConfigHostsTest do
  use Voyager.DataCase, async: true

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Voyager.MCP.Server
  alias Voyager.MCP.Tools.ListSshConfigHosts
  alias Voyager.Settings

  @moduletag :tmp_dir

  test "is registered on the MCP server" do
    assert ListSshConfigHosts in Enum.map(Server.__components__(:tool), & &1.handler)
  end

  test "returns an error naming an unreadable path", %{tmp_dir: dir} do
    path = Path.join(dir, "missing")
    {:ok, _} = Settings.put(:ssh_config_path, path)

    assert {:reply, %Response{isError: true, content: [%{"text" => text}]}, %Frame{}} =
             ListSshConfigHosts.execute(%{}, %Frame{})

    assert text =~ path
  end

  test "maps every field to the connect argument names", %{tmp_dir: dir} do
    config = """
    Host staging
      HostName 10.0.4.12
      User deploy
      Port 2222
      IdentityFile /keys/id_ed25519
      IdentityAgent /agent.sock
    """

    assert hosts!(dir, config) == [
             %{
               "alias" => "staging",
               "ssh_host" => "10.0.4.12",
               "ssh_user" => "deploy",
               "ssh_port" => 2222,
               "key_path" => "/keys/id_ed25519",
               "agent_socket_path" => "/agent.sock"
             }
           ]
  end

  test "falls back to the alias, null and port 22 for unset fields", %{tmp_dir: dir} do
    assert [
             %{
               "ssh_host" => "bare",
               "ssh_user" => nil,
               "ssh_port" => 22,
               "key_path" => nil,
               "agent_socket_path" => nil
             }
           ] = hosts!(dir, "Host bare\n")
  end

  test "returns null for IdentityAgent none", %{tmp_dir: dir} do
    assert [%{"agent_socket_path" => nil}] = hosts!(dir, "Host a\n  IdentityAgent none\n")
  end

  test "returns the first of several identity files", %{tmp_dir: dir} do
    config = "Host a\n  IdentityFile /keys/first\n  IdentityFile /keys/second\n"

    assert [%{"key_path" => "/keys/first"}] = hosts!(dir, config)
  end

  defp hosts!(dir, contents) do
    path = Path.join(dir, "config")
    File.write!(path, contents)
    {:ok, _} = Settings.put(:ssh_config_path, path)

    assert {:reply, %Response{isError: false, content: [%{"text" => json}]}, %Frame{}} =
             ListSshConfigHosts.execute(%{}, %Frame{})

    JSON.decode!(json)["hosts"]
  end
end
