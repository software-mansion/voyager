defmodule Voyager.Services.UsedRequestStates do
  @moduledoc """
  Remembers the ids of answered MCP request states, so each answer is acted on once.
  An id is kept for the anubis `:request_state_ttl`, after which its state is refused anyway.
  """

  use GenServer

  @table __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Marks `id` as used. Returns `:used` if it already was."
  @spec consume(term()) :: :ok | :used
  def consume(id) do
    now = System.system_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :"$1"}, [{:<, :"$1", now}], [true]}])
    expires_at = now + Application.fetch_env!(:anubis_mcp, :request_state_ttl)

    if :ets.insert_new(@table, {id, expires_at}), do: :ok, else: :used
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:set, :public, :named_table])
    {:ok, nil}
  end
end
