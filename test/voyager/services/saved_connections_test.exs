defmodule Voyager.Services.SavedConnectionsTest do
  use ExUnit.Case, async: true

  alias Voyager.Schemas.SshConnection
  alias Voyager.Services.SavedConnections
  alias Voyager.Test.SshKeys

  @moduletag :tmp_dir

  describe "ready?/1" do
    test "is ready when the key has no passphrase", %{tmp_dir: dir} do
      {path, _pub} = SshKeys.ssh_keygen!(dir, "id_ed25519", ["-t", "ed25519", "-N", ""])

      assert SavedConnections.ready?(ssh(path))
    end

    test "is not ready for an encrypted OpenSSH key", %{tmp_dir: dir} do
      {path, _pub} = SshKeys.ssh_keygen!(dir, "id_ed25519", ~w(-t ed25519 -a 1 -N secret))

      refute SavedConnections.ready?(ssh(path))
    end
  end

  defp ssh(key_path) do
    %SshConnection{cookie: "secret", auth_method: :key, key_path: key_path}
  end
end
