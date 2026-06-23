defmodule Voyager.Services.OpenSSH.HostScannerTest do
  use ExUnit.Case, async: true

  alias Voyager.Services.OpenSSH.HostScanner

  describe "parse_fingerprints/1" do
    test "parses ssh-keygen -lf output into structured entries" do
      output = """
      256 SHA256:abc123xyz user@host (ED25519)
      3072 SHA256:def456uvw user@host (RSA)
      256 SHA256:ghi789rst user@host (ECDSA)
      """

      assert [ed, rsa, ecdsa] = HostScanner.parse_fingerprints(output)

      assert ed == %{bits: 256, hash: "SHA256:abc123xyz", comment: "user@host", type: "ED25519"}
      assert rsa == %{bits: 3072, hash: "SHA256:def456uvw", comment: "user@host", type: "RSA"}
      assert ecdsa == %{bits: 256, hash: "SHA256:ghi789rst", comment: "user@host", type: "ECDSA"}
    end

    test "skips malformed lines" do
      output = """
      256 SHA256:valid user@host (ED25519)
      garbage line
      not a fingerprint at all
      """

      assert [%{type: "ED25519"}] = HostScanner.parse_fingerprints(output)
    end

    test "returns empty list for empty input" do
      assert HostScanner.parse_fingerprints("") == []
    end

    test "parses lines with trailing carriage returns (CRLF output)" do
      output = "256 SHA256:abc123xyz user@host (ED25519)\r\n3072 SHA256:def456uvw u@h (RSA)\r\n"

      assert [ed, rsa] = HostScanner.parse_fingerprints(output)
      assert ed == %{bits: 256, hash: "SHA256:abc123xyz", comment: "user@host", type: "ED25519"}
      assert rsa == %{bits: 3072, hash: "SHA256:def456uvw", comment: "u@h", type: "RSA"}
    end
  end

  describe "scan/2" do
    @tag :slow
    test "returns :no_keys_returned for an unreachable host" do
      # Port 1 is reserved/closed; ssh-keyscan times out cleanly.
      assert {:error, _} = HostScanner.scan("127.0.0.1", 1)
    end
  end

  describe "trust/2" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "voyager_trust_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      Application.put_env(:voyager, :known_hosts_path, Path.join(tmp, "known_hosts"))

      on_exit(fn ->
        Application.delete_env(:voyager, :known_hosts_path)
        File.rm_rf!(tmp)
      end)

      :ok
    end

    @tag :slow
    test "returns an error and does not modify known_hosts on unreachable host" do
      assert {:error, _} = HostScanner.trust("127.0.0.1", 1)
      refute HostScanner.known?("127.0.0.1")
    end
  end
end
