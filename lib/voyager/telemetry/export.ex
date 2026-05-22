defmodule Voyager.Telemetry.Export do
  @moduledoc """
  Exports telemetry events to a remote telemetry server via `Req`.
  `send/1` schedules an asynchronous task under a `Task.Supervisor`, so callers never block.
  Failed pushes are retried with backoff.

  Set `:telemetry_push_url` (via the `TELEMETRY_PUSH_URL` environment variable) to your telemetry server's push API endpoint, for example:

      config :voyager, telemetry_push_url: "http://127.0.0.1:3100/loki/api/v1/push"
  """

  require Logger

  @max_retries 3
  @backoff_ms [500, 1000, 10_000]

  @doc "Schedules an async export task. Never blocks the caller."
  @spec send(map()) :: :ok
  def send(payload) when is_map(payload) do
    case Task.Supervisor.start_child(Voyager.Telemetry.ExportTaskSupervisor, fn ->
           push_with_retry(payload, 0)
         end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning("[telemetry] failed to start export task: #{inspect(reason)}")
        :ok
    end
  end

  defp push_with_retry(payload, attempt) do
    case push(payload) do
      :ok ->
        :ok

      {:error, reason} = error ->
        if retry?(error, attempt) do
          Process.sleep(backoff_ms(attempt))
          push_with_retry(payload, attempt + 1)
        else
          Logger.warning("[telemetry] giving up after #{attempt} retries: #{inspect(reason)}")

          :ok
        end
    end
  end

  defp push(payload) do
    case Application.get_env(:voyager, :telemetry_push_url) do
      url when is_binary(url) and url != "" ->
        case Req.post(url, json: payload) do
          {:ok, %Req.Response{status: status}} when status in 200..299 ->
            :ok

          {:ok, %Req.Response{status: status}} ->
            {:error, {:http_status, status}}

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, "TELEMETRY_PUSH_URL not set"}
    end
  end

  defp retry?({:error, "TELEMETRY_PUSH_URL not set"}, _attempt), do: false
  defp retry?(_error, attempt), do: attempt < @max_retries

  defp backoff_ms(attempt), do: Enum.at(@backoff_ms, attempt, 2000)
end
