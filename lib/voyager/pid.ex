defmodule Voyager.Pid do
  @moduledoc """
  Converts PIDs to and from their `"<X.Y.Z>"` string representation.
  """

  @spec display(pid()) :: String.t()
  def display(pid) when is_pid(pid), do: pid |> :erlang.pid_to_list() |> List.to_string()

  @spec parse(String.t()) :: pid() | nil
  def parse(pid_str) when is_binary(pid_str) do
    pid_str |> String.trim_leading("#PID") |> String.to_charlist() |> :erlang.list_to_pid()
  rescue
    ArgumentError -> nil
  end

  def parse(_pid_str), do: nil
end
