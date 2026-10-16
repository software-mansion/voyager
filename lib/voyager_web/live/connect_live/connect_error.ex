defmodule VoyagerWeb.ConnectLive.ConnectError do
  @moduledoc """
  User-facing messages for `NodeSession` connect failures from either connector.
  """

  @spec message(term()) :: String.t()
  def message(:connection_failed),
    do: "Node unreachable - check the name is correct and the node is running"

  def message(:epmd_timeout),
    do: "Node unreachable - the host didn't respond in time, check your network connection"

  def message({:epmd_error, :nxdomain}), do: "Host not found - check the node's hostname"

  def message({:epmd_error, :address}),
    do: "Could not reach epmd on the host - check the hostname and that epmd is running"

  def message({tag, reason})
      when tag in [:epmd_error, :node_unreachable] and reason in [:etimedout, :timeout],
      do: "Connection timed out - check the node's hostname and your network"

  def message({:epmd_error, _reason}), do: "Could not reach host"

  def message(:node_not_registered),
    do: "Node not found - check the node name is correct and the node is running"

  def message({:node_unreachable, :econnrefused}),
    do: "Connection refused - check the node is running"

  def message({:node_unreachable, reason})
      when reason in [:ehostunreach, :enetunreach, :enetdown, :ehostdown],
      do: "Host unreachable - check the node's hostname and your network"

  def message({:node_unreachable, _reason}),
    do: "Node port unreachable - check the node is running"

  def message(:bad_cookie), do: "Authentication failed - the Erlang cookie does not match"

  def message(:name_type_mismatch),
    do: "Name type mismatch - try switching between --sname and --name"

  def message({:invalid_node_name, _}), do: "Use the name@host format"
  def message({:invalid_host, _}), do: "Invalid host — check the SSH hostname"

  def message(reason) when is_list(reason),
    do: "SSH authentication failed — check your credentials or ensure the SSH agent is running"

  def message(:etimedout), do: "Connection timed out — check the SSH host and port"
  def message(:econnrefused), do: "Connection refused — check the SSH host and port"
  def message(:nxdomain), do: "Host not found — check the SSH hostname"

  def message(reason) when reason in [:ehostunreach, :enetunreach, :enetdown, :ehostdown],
    do: "Host unreachable — check the SSH hostname and your network"

  def message({:node_not_found, _, _}),
    do:
      "Node not found on remote epmd — check the node name, or set a custom EPMD port in Advanced"

  def message(:invalid_epmd_response),
    do: "Unexpected response from remote epmd — check the EPMD port in Advanced"

  def message(:node_connect_failed), do: "Handshake failed — the Erlang cookie does not match"
  def message(:invalid_name_type), do: "Invalid name type"
  def message(:not_distributed), do: "Failed to start local Erlang distribution"
  def message({:net_kernel, _}), do: "Failed to start local Erlang distribution"
  def message({:net_kernel_stop, _}), do: "Failed to restart local Erlang distribution"
  def message(:unexpected_exit), do: "Connection attempt failed unexpectedly"

  def message({:agent_install_failed, {:otp_too_old, release}}),
    do: "Node runs OTP #{release} - Voyager requires OTP #{Voyager.Agent.min_otp()} or newer"

  def message({:agent_install_failed, _}), do: "Could not load the Voyager agent on the node"

  def message(:key_encrypted_openssh),
    do: "Passphrase-protected OpenSSH keys aren't supported — use SSH Agent or Password"

  def message(:key_unreadable), do: "Not a private key Voyager can read"
  def message({:read_failed, _}), do: "Can't read this file"
  def message(_reason), do: "Could not connect to node"
end
