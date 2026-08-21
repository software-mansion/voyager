defmodule Voyager.Epmd.Client do
  @moduledoc """
  Raw TCP client for communicating with EPMD.
  """

  @epmd_names_req 110

  @doc """
  Sends a NAMES_REQ to the EPMD running at `host`:`port`.
  """
  @spec get_names(:inet.ip_address() | :inet.hostname(), :inet.port_number(), timeout()) ::
          {:ok, String.t()} | {:error, term()}
  def get_names(host \\ ~c"127.0.0.1", port \\ 4369, timeout \\ 1_000) do
    opts = [:binary, active: false, packet: :raw]

    with {:ok, sock} <- :gen_tcp.connect(host, port, opts, timeout),
         :ok <- :gen_tcp.send(sock, <<1::16, @epmd_names_req>>),
         {:ok, resp} <- recv_until_closed(sock, <<>>, timeout) do
      :gen_tcp.close(sock)
      parse_names_response(resp)
    else
      err -> err
    end
  end

  defp recv_until_closed(sock, acc, timeout) do
    case :gen_tcp.recv(sock, 0, timeout) do
      {:ok, data} -> recv_until_closed(sock, acc <> data, timeout)
      {:error, :closed} -> {:ok, acc}
      {:error, _} = err -> err
    end
  end

  defp parse_names_response(<<_epmd_port::32, text::binary>>), do: {:ok, text}
  defp parse_names_response(_), do: {:error, :invalid_epmd_response}
end
