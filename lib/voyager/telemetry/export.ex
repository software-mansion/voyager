defmodule Voyager.Telemetry.Export do
  @moduledoc """
  Exports telemetry events to a remote telemetry server via `Req`. Each `send/1` cast is handled
  in order by this process; the GenServer mailbox serves as the queue.

  Set `:telemetry_push_url` (via the `TELEMETRY_PUSH_URL` environment variable) to your telemetry server's push API endpoint, for example:

      config :voyager, telemetry_push_url: "http://127.0.0.1:3100/loki/api/v1/push"
  """

  use GenServer

  require Logger

  @telemetry_push_url Application.compile_env(:voyager, :telemetry_push_url)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Queues an export cast. Never blocks the caller."
  @spec send(map()) :: :ok
  def send(payload) when is_map(payload) do
    GenServer.cast(__MODULE__, {:send, payload})
  end

  @impl GenServer
  def init(_opts) do
    {:ok, %{}}
  end

  @impl GenServer
  def handle_cast({:send, payload}, state) do
    push(payload)
    {:noreply, state}
  end

  @doc false
  @spec push(map()) :: :ok | {:error, String.t()}
  def push(payload) do
    case @telemetry_push_url do
      url when is_binary(url) and url != "" ->
        case Req.post(url, json: payload) do
          {:ok, %Req.Response{status: status}} when status in 200..299 ->
            Logger.info("[telemetry] push to #{url} successful: #{status}")
            :ok

          {:ok, %Req.Response{status: status} = resp} ->
            Logger.warning(
              "[telemetry] push returned #{status}: #{inspect(resp.body, limit: 200)}"
            )

          {:error, reason} ->
            Logger.warning("[telemetry] push failed: #{inspect(reason)}")
        end

      _ ->
        {:error, "TELEMETRY_PUSH_URL not set"}
    end
  end
end
