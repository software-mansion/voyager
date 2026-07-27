defmodule Voyager.Telemetry.Handler.Export do
  @moduledoc """
  Exports telemetry events to a remote telemetry server via `Req`.
  `send_event/3` schedules an asynchronous task under a `Task.Supervisor`, so callers never block.
  Failed pushes are retried with backoff.

  Set `:push_url` (via `TELEMETRY_PUSH_URL`) and `:api_key` (via `TELEMETRY_API_KEY`).
  Events are posted to the ingest server with the `X-API-Key` header.
  """

  @behaviour Voyager.Telemetry.Handler

  alias Voyager.Telemetry.Parser

  require Logger

  @max_retries 3
  @backoff_ms [500, 1000, 10_000]
  @api_key_header "x-api-key"

  @impl true
  def handle_event(event, measurements, metadata, config) when is_map(config) do
    case config do
      %{push_url: push_url, api_key: api_key} when is_binary(push_url) and is_binary(api_key) ->
        payload = %{
          event: Parser.parse_event(event),
          measurements: Parser.parse_measurements(event, measurements),
          metadata: Parser.parse_metadata(event, metadata),
          ts: System.system_time(:millisecond)
        }

        send_event(push_url, api_key, payload)

      config ->
        Logger.warning(
          "[telemetry] telemetry config invalid: #{inspect(Map.keys(config))}. Expected %{push_url: binary(), api_key: binary()}"
        )
    end

    :ok
  end

  @doc "Schedules an async export task. Never blocks the caller."
  @spec send_event(String.t(), String.t(), map()) :: :ok
  def send_event(url, api_key, payload)
      when is_binary(url) and is_binary(api_key) and is_map(payload) do
    case Task.Supervisor.start_child(Voyager.Telemetry.ExportTaskSupervisor, fn ->
           push_with_retry(url, api_key, payload, 0)
         end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning("[telemetry] failed to start export task: #{inspect(reason)}")
        :ok
    end
  end

  defp push_with_retry(url, api_key, payload, attempt) do
    case push(url, api_key, payload) do
      :ok ->
        :ok

      {:error, reason} ->
        if attempt < @max_retries do
          Process.sleep(backoff_ms(attempt))
          push_with_retry(url, api_key, payload, attempt + 1)
        else
          Logger.warning("[telemetry] giving up after #{attempt} retries: #{inspect(reason)}")

          :ok
        end
    end
  end

  defp push(url, api_key, payload) do
    case Req.post(url, json: payload, headers: [{@api_key_header, api_key}]) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp backoff_ms(attempt), do: Enum.at(@backoff_ms, attempt, 2000)
end
