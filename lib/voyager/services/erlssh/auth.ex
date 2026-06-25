defmodule Voyager.Services.Erlssh.Auth do
  @moduledoc """
  Shared auth type for Erlang SSH connections.
  """

  @type auth :: :agent | {:password, String.t()}
end
