defmodule Voyager.MCP.Tools.ConnectTest do
  # async: false because `Voyager.NodeSession` and the ElixirKit.PubSub name are global.
  use Voyager.DataCase, async: false

  import Voyager.TestUtils

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Voyager.Fakes
  alias Voyager.MCP.Tools.Connect
  alias Voyager.NodeSession
  alias Voyager.NodeSession.Connectors.Ssh, as: SshConnector
  alias Voyager.Schemas.Connection
  alias Voyager.Schemas.SshConnection
  alias Voyager.Test.SshKeys

  @ssh_meta %{ssh_user: "deploy", ssh_host: "gw", ssh_port: 22, epmd_port: 4369}

  setup do
    previous_state = :sys.get_state(NodeSession)
    Fakes.put_session(nil)
    on_exit(fn -> :sys.replace_state(NodeSession, fn _ -> previous_state end) end)
  end

  describe "arguments" do
    test "rejects an unknown connection_id" do
      %{"connection_id" => "direct:999"} |> execute() |> assert_error()
      %{"connection_id" => "nope"} |> execute() |> assert_error()
    end

    test "needs a connection_id or a node_name" do
      %{} |> execute() |> assert_error()
    end

    test "needs both SSH user and host" do
      %{"node_name" => "app@10.0.0.5", "ssh_host" => "gw"} |> execute() |> assert_error()
    end

    test "refuses SSH without the proxy epmd module" do
      %{"node_name" => "app@10.0.0.5", "ssh_user" => "u", "ssh_host" => "gw"}
      |> execute()
      |> assert_error()
    end

    test "refuses a saved SSH connection without the proxy epmd module" do
      conn = insert!(%SshConnection{ssh_user: "u", ssh_host: "gw", node_name: "app@10.0.0.5"})
      Process.register(self(), ElixirKit.PubSub)

      %{"connection_id" => "ssh:#{conn.id}"} |> execute() |> assert_error()

      refute_received {:"$gen_cast", {:broadcast, "messages", _}}
    end

    test "has no secret fields" do
      assert {:ok, params} =
               Connect.mcp_schema(%{"node_name" => "app@host", "cookie" => "secret"})

      refute Map.has_key?(params, :cookie)
    end
  end

  describe "while connected" do
    test "reports the node it is already connected to" do
      conn = insert!(%Connection{node_name: "shop@10.0.4.12"})
      Fakes.connect_node!(Fakes.node_session(node_name: "shop@10.0.4.12"))

      assert %{"status" => "connected", "node" => "shop@10.0.4.12"} =
               %{"connection_id" => "direct:#{conn.id}"} |> execute() |> run()
    end

    test "refuses another node and points at disconnect" do
      Fakes.connect_node!(Fakes.node_session(node_name: "shop@10.0.4.12"))

      %{"node_name" => "other@10.0.4.13"} |> execute() |> assert_error()
    end

    test "treats the same node name behind another SSH host as another node" do
      enable_proxy_epmd(%{})
      session = Fakes.node_session(node_name: "app@127.0.0.1", connector: SshConnector)
      Fakes.connect_node!(%{session | meta: %{@ssh_meta | ssh_host: "a"}})

      %{"node_name" => "app@127.0.0.1", "ssh_user" => "deploy", "ssh_host" => "b"}
      |> execute()
      |> assert_error()
    end

    test "treats the same SSH host on another port as another node" do
      enable_proxy_epmd(%{})
      insert!(%SshConnection{ssh_user: "deploy", ssh_host: "gw", node_name: "app@127.0.0.1"})
      session = Fakes.node_session(node_name: "app@127.0.0.1", connector: SshConnector)
      Fakes.connect_node!(%{session | meta: @ssh_meta})
      args = %{"node_name" => "app@127.0.0.1", "ssh_user" => "deploy", "ssh_host" => "gw"}

      assert %{"status" => "connected"} = args |> execute() |> run()
      args |> Map.put("ssh_port", 2222) |> execute() |> assert_error()
      args |> Map.put("epmd_port", 14_369) |> execute() |> assert_error()
    end
  end

  describe "a saved connection with its secrets" do
    test "connects without user input and reports a failure" do
      started_here? = not Node.alive?()
      on_exit(fn -> if started_here? and Node.alive?(), do: :net_kernel.stop() end)

      conn = insert!(%Connection{node_name: "gone@127.0.0.1", cookie: "secret"})
      Process.register(self(), ElixirKit.PubSub)

      %{"connection_id" => "direct:#{conn.id}"} |> execute() |> assert_error()

      refute_received {:"$gen_cast", {:broadcast, "messages", _}}
    end
  end

  describe "a connection missing a secret" do
    test "opens the Voyager connect form for a saved connection" do
      conn = insert!(%Connection{node_name: "nocookie@host"})
      Process.register(self(), ElixirKit.PubSub)

      assert %{"status" => "awaiting_user"} =
               payload = %{"connection_id" => "direct:#{conn.id}"} |> execute() |> run()

      refute Map.has_key?(payload, "url")

      assert_received {:"$gen_cast", {:broadcast, "messages", path}}
      assert path == "open:/?connection=#{conn.id}"
    end

    test "opens the SSH form pre-filled for a node that is not saved" do
      enable_proxy_epmd(%{})
      Process.register(self(), ElixirKit.PubSub)

      assert %{"status" => "awaiting_user"} =
               %{
                 "node_name" => "app@10.0.0.5",
                 "ssh_user" => "deploy",
                 "ssh_host" => "gw",
                 "auth_method" => "password"
               }
               |> execute()
               |> run()

      assert_received {:"$gen_cast", {:broadcast, "messages", "open:" <> path}}

      assert %{
               "mode" => "ssh",
               "node_name" => "app@10.0.0.5",
               "ssh_user" => "deploy",
               "ssh_host" => "gw",
               "ssh_port" => "22",
               "auth_method" => "password"
             } = path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    end

    @tag :tmp_dir
    test "opens the SSH form with the key path for a passphrase-protected key", %{tmp_dir: dir} do
      enable_proxy_epmd(%{})
      Process.register(self(), ElixirKit.PubSub)
      key = :public_key.generate_key({:namedCurve, :secp256r1})
      {key_path, _pub} = SshKeys.pem!(dir, "id_ecdsa", key, "passphrase")

      assert %{"status" => "awaiting_user"} =
               %{
                 "node_name" => "app@10.0.0.5",
                 "ssh_user" => "deploy",
                 "ssh_host" => "gw",
                 "auth_method" => "key",
                 "key_path" => key_path
               }
               |> execute()
               |> run()

      assert_received {:"$gen_cast", {:broadcast, "messages", "open:" <> path}}

      assert %{"auth_method" => "key", "key_path" => ^key_path} =
               path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    end

    test "opens the SSH form on key auth when no key path is given" do
      enable_proxy_epmd(%{})
      Process.register(self(), ElixirKit.PubSub)

      assert %{"status" => "awaiting_user"} =
               %{
                 "node_name" => "app@10.0.0.5",
                 "ssh_user" => "deploy",
                 "ssh_host" => "gw",
                 "auth_method" => "key"
               }
               |> execute()
               |> run()

      assert_received {:"$gen_cast", {:broadcast, "messages", "open:" <> path}}

      query = path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      assert %{"auth_method" => "key"} = query
      refute Map.has_key?(query, "key_path")
    end

    test "matches a saved SSH profile by its fields" do
      enable_proxy_epmd(%{})

      conn =
        insert!(%SshConnection{ssh_user: "deploy", ssh_host: "gw", node_name: "app@10.0.0.5"})

      Process.register(self(), ElixirKit.PubSub)

      %{"node_name" => "app@10.0.0.5", "ssh_user" => "deploy", "ssh_host" => "gw"}
      |> execute()
      |> run()

      assert_received {:"$gen_cast", {:broadcast, "messages", path}}
      assert path == "open:/?mode=ssh&connection=#{conn.id}"
    end

    test "returns a URL to open when no desktop shell is attached" do
      assert %{"status" => "awaiting_user", "url" => url} =
               %{"node_name" => "app@host"} |> execute() |> run()

      assert url =~ "/?node_name=app%40host&name_type=longnames"
    end
  end

  defp insert!(connection) do
    Repo.insert!(%{
      connection
      | last_connected_at: DateTime.truncate(DateTime.utc_now(), :second)
    })
  end

  defp execute(args) do
    {:ok, params} = Connect.mcp_schema(args)
    Connect.execute(params, %Frame{})
  end

  defp run(result) do
    assert {:reply, %Response{isError: false, content: [%{"text" => json}]}, %Frame{}} = result
    JSON.decode!(json)
  end

  defp assert_error(result) do
    assert {:reply, %Response{isError: true, content: [%{"text" => _}]}, %Frame{}} = result
  end
end
