defmodule Voyager.Services.Erlssh.Auth do
  @moduledoc """
  Shared auth type for Erlang SSH connections.
  """

  @type auth :: :agent | {:password, String.t()}

  defguard is_ssh_auth(auth)
           when auth == :agent or
                  (is_tuple(auth) and tuple_size(auth) == 2 and elem(auth, 0) == :password and
                     is_binary(elem(auth, 1)))
end
