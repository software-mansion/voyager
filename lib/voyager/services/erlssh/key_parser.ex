defmodule Voyager.Services.Erlssh.KeyParser do
  @moduledoc false

  @behaviour :ssh_client_key_api

  @impl true
  def user_key(_algorithm, options) do
    user_path = Keyword.get(options, :user_key_file)

    [pem_entry] = user_path |> Path.expand() |> File.read!() |> :public_key.pem_decode()

    {:ok, :public_key.pem_entry_decode(pem_entry)}
  end
end
