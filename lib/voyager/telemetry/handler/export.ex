defmodule Voyager.Telemetry.Handler.Export do
  @moduledoc """
  Exports telemetry events to a remote telemetry server via `Req`.
  `send/1` schedules an asynchronous task under a `Task.Supervisor`, so callers never block.
  Failed pushes are retried with backoff.

  Set `:telemetry_push_url` (via the `TELEMETRY_PUSH_URL` environment variable) to your telemetry server's push API endpoint, for example:

      config :voyager, telemetry_push_url: "http://127.0.0.1:3100/loki/api/v1/push"
  """

  @behaviour Voyager.Telemetry.Handler

  alias Voyager.Telemetry.Parser

  require Logger

  @max_retries 3
  @backoff_ms [500, 1000, 10_000]
  @telemetry_push_url Application.compile_env(:voyager, :telemetry_push_url)

  def telemetry_push_url do
    @telemetry_push_url
  end

  @impl true
  @spec handle_event([atom()], any(), map(), any()) :: :ok
  def handle_event(event, measurements, metadata, config) do
    payload = %{
      event: Parser.parse_event(event),
      measurements: measurements,
      metadata: Parser.parse_metadata(event, metadata),
      ts: System.system_time(:millisecond)
    }

    case config do
      %{telemetry_push_url: push_url} ->
        send_event(push_url, payload)

      _ ->
        Logger.warning("[telemetry] TELEMETRY_PUSH_URL not set")
    end

    :ok
  end

  @doc "Schedules an async export task. Never blocks the caller."
  @spec send_event(String.t(), map()) :: :ok
  def send_event(url, payload) when is_binary(url) and is_map(payload) do
    case Task.Supervisor.start_child(Voyager.Telemetry.ExportTaskSupervisor, fn ->
           push_with_retry(url, payload, 0)
         end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning("[telemetry] failed to start export task: #{inspect(reason)}")
        :ok
    end
  end

  defp push_with_retry(url, payload, attempt) do
    case push(url, payload) do
      :ok ->
        :ok

      {:error, reason} ->
        if attempt < @max_retries do
          Process.sleep(backoff_ms(attempt))
          push_with_retry(url, payload, attempt + 1)
        else
          Logger.warning("[telemetry] giving up after #{attempt} retries: #{inspect(reason)}")

          :ok
        end
    end
  end

  defp push(url, payload) do
    case Req.post(url, json: payload) do
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
