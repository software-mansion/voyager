defmodule VoyagerWeb.ConnectLiveSshConfigTest do
  use ExUnit.Case, async: true

  alias VoyagerWeb.ConnectLive.SshConfigImport
  alias VoyagerWeb.FormSchemas.SshConnectionParams

  @prod %{
    alias: "prod",
    host_name: "10.0.0.5",
    user: "deploy",
    port: 2222,
    identity_files: [],
    identity_agent: nil
  }
  @bare %{
    alias: "bare",
    host_name: nil,
    user: nil,
    port: nil,
    identity_files: [],
    identity_agent: nil
  }

  defp form(params) do
    params |> SshConnectionParams.changeset() |> Phoenix.Component.to_form(as: :ssh)
  end

  describe "selected_host/2" do
    test "finds the host a fill produced" do
      for host <- [@prod, @bare] do
        form = form(SshConnectionParams.params_from_host(host))

        assert SshConfigImport.selected_host([@prod, @bare], form) == host
      end
    end

    test "matches the schema's default port" do
      form = form(%{"ssh_host" => "bare"})

      assert SshConfigImport.selected_host([@bare], form) == @bare
    end

    test "stops matching once a server field is edited" do
      params = @prod |> SshConnectionParams.params_from_host() |> Map.put("ssh_port", "22")

      assert SshConfigImport.selected_host([@prod], form(params)) == nil
    end

    test "ignores an edited key path" do
      params = @prod |> SshConnectionParams.params_from_host() |> Map.put("key_path", "/k/other")

      assert SshConfigImport.selected_host([@prod], form(params)) == @prod
    end

    test "returns nil before an import" do
      assert SshConfigImport.selected_host(nil, form(%{})) == nil
    end
  end
end
