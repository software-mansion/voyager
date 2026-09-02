defmodule Voyager.Epmd.ClientTest do
  use ExUnit.Case, async: true

  alias Voyager.Epmd.Client

  describe "get_names/3" do
    test "sends NAMES_REQ and returns names text" do
      parent = self()

      {task, port} =
        start_server(fn socket ->
          {:ok, request} = :gen_tcp.recv(socket, 0, 1_000)

          send(parent, {:request, request})

          :ok =
            :gen_tcp.send(
              socket,
              <<0, 0, 0, 0, "name voyager at port 1234\n">>
            )
        end)

      assert {:ok, "name voyager at port 1234\n"} =
               Client.get_names(~c"127.0.0.1", port, 1_000)

      assert_receive {:request, <<1::16, 110>>}

      Task.await(task)
    end

    test "returns invalid response for response shorter than 4 bytes" do
      {task, port} =
        start_server(fn socket ->
          :ok = :gen_tcp.send(socket, <<1, 2, 3>>)
        end)

      assert {:error, :invalid_epmd_response} =
               Client.get_names(~c"127.0.0.1", port, 1_000)

      Task.await(task)
    end

    test "returns timeout when server does not respond" do
      {task, port} =
        start_server(fn _socket ->
          Process.sleep(100)
        end)

      assert {:error, :timeout} =
               Client.get_names(~c"127.0.0.1", port, 10)

      Task.await(task)
    end

    test "returns error when connection is refused" do
      assert {:error, _reason} =
               Client.get_names(~c"127.0.0.1", 1, 100)
    end

    test "works with a running real EPMD" do
      assert {:ok, text} =
               Client.get_names(~c"127.0.0.1", 4369, 500)

      assert is_binary(text)
    end
  end

  defp start_server(handler) do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        reuseaddr: true
      ])

    {:ok, {_address, port}} = :inet.sockname(listener)

    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)

        try do
          handler.(socket)
        after
          :gen_tcp.close(socket)
          :gen_tcp.close(listener)
        end
      end)

    {task, port}
  end
end
