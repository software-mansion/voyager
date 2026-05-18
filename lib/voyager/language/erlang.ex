defmodule Voyager.Language.Erlang do
  @moduledoc false

  @behaviour Voyager.Language

  alias Voyager.RPC.ERPC

  @impl Voyager.Language
  def detect?(_apps), do: true

  @impl Voyager.Language
  def name, do: "Erlang"

  @impl Voyager.Language
  def info(node) do
    %{
      otp_release: node |> ERPC.fetch(:erlang, :system_info, [:otp_release]) |> charlist_to_str(),
      erts_version: node |> ERPC.fetch(:erlang, :system_info, [:version]) |> charlist_to_str()
    }
  end

  defp charlist_to_str(nil), do: nil
  defp charlist_to_str(chars), do: List.to_string(chars)
end
