defmodule VoyagerWeb.EtsTablesLive.Fetcher do
  @moduledoc """
  Owns the ETS list's fetch lifecycle: the async fetch and its rate limiting,
  auto-refresh, and the assigns the page renders from (`page_result`,
  `last_updated`, `round_trip_ms`, `refresh_interval`).

  The first fetch waits for the client's stored controls (`start/1`), so a
  visit costs one fetch. One fetch returns every table's metadata, so at most
  one runs at a time; a request landing mid-fetch is queued and replayed when
  it finishes.

  Reads `session` and `controls` (for the request timeout) from the socket.
  """

  import Phoenix.Component
  import Phoenix.LiveView

  alias Phoenix.LiveView.AsyncResult
  alias Phoenix.LiveView.Socket
  alias Voyager.Services.RateLimiter
  alias VoyagerWeb.EtsTablesLive.Query

  require Logger

  @refetch_debounce_ms 1_500

  # A fetch resolving in a few ms flashes the loading state for a frame; hold
  # it so the transition reads as intentional. Zeroed in test.
  @min_fetch_ms Application.compile_env(:voyager, :min_fetch_ms, 300)

  # Slower floor than the process list's: every refresh carries the whole
  # table list over the wire.
  @interval_options [
    {"Off", "off"},
    {"5s", "5000"},
    {"10s", "10000"},
    {"30s", "30000"},
    {"60s", "60000"}
  ]
  @default_interval_ms 5_000

  @doc "Auto-refresh choices as `{label, value}` pairs."
  @spec interval_options() :: [{String.t(), String.t()}]
  def interval_options, do: @interval_options

  @doc """
  Assigns the fetch state and attaches the timer and result handlers.

  Deliberately starts nothing: the view calls `start/1` once the client has
  restored its stored controls. The result handler continues to the view's
  `handle_async/3`, so the page can recompute what it derives from the entries
  (its filtered rows, the selected table) after the assigns update.
  """
  @spec init(Socket.t()) :: Socket.t()
  def init(socket) do
    socket
    # Not `loading/0`: with a fetch seemingly in flight, `fetch/1` would queue
    # the first one instead of starting it. The table reads this as loading
    # anyway, since it has no result yet.
    |> assign(:page_result, %AsyncResult{})
    |> assign(:refetch_timer, nil)
    |> assign(:refetch_queued?, false)
    |> assign(:refresh_interval, @default_interval_ms)
    |> assign(:refresh_timer, nil)
    |> assign(:last_updated, nil)
    |> assign(:round_trip_ms, nil)
    |> attach_hook(:ets_fetch_timers, :handle_info, &handle_timer/2)
    |> attach_hook(:ets_fetch_result, :handle_async, &handle_result/3)
  end

  @doc "Runs the first fetch and arms the auto-refresh, once the controls are known."
  @spec start(Socket.t()) :: Socket.t()
  def start(socket) do
    if connected?(socket),
      do: socket |> start_fetch(:high) |> restart_refresh_timer(),
      else: socket
  end

  @doc "Collapses a burst of control changes into one fetch, fired once the user pauses."
  @spec debounce_refetch(Socket.t()) :: Socket.t()
  def debounce_refetch(socket) do
    if timer = socket.assigns.refetch_timer, do: Process.cancel_timer(timer)
    assign(socket, :refetch_timer, Process.send_after(self(), :refetch, @refetch_debounce_ms))
  end

  @doc """
  Starts a fetch, or queues one if a fetch is already running.

  `:low` is for background refreshes, which the rate limiter may skip.
  """
  @spec fetch(Socket.t(), :high | :low) :: Socket.t()
  def fetch(socket, priority \\ :high) do
    if loading?(socket.assigns.page_result),
      do: assign(socket, :refetch_queued?, true),
      else: start_fetch(socket, priority)
  end

  @doc "Sets auto-refresh from an `interval_options/0` value; anything else turns it off."
  @spec set_interval(Socket.t(), String.t()) :: Socket.t()
  def set_interval(socket, value) do
    socket
    |> assign(:refresh_interval, parse_interval(value))
    |> restart_refresh_timer()
  end

  @spec loading?(struct()) :: boolean()
  def loading?(%AsyncResult{loading: loading}), do: loading != nil

  @spec entries(struct()) :: [Query.table()]
  def entries(%AsyncResult{ok?: true, result: %{entries: entries}}), do: entries
  def entries(_page_result), do: []

  defp handle_timer(:refetch, socket) do
    {:halt, socket |> assign(:refetch_timer, nil) |> fetch()}
  end

  defp handle_timer(:auto_refresh, socket) do
    {:halt, socket |> restart_refresh_timer() |> fetch(:low)}
  end

  defp handle_timer(_message, socket), do: {:cont, socket}

  defp handle_result(:page_result, result, socket), do: {:cont, apply_result(result, socket)}
  defp handle_result(_name, _result, socket), do: {:cont, socket}

  defp apply_result({:ok, {:ok, page, round_trip_ms}}, socket) do
    socket
    |> assign(:page_result, AsyncResult.ok(socket.assigns.page_result, page))
    |> assign(:round_trip_ms, round_trip_ms)
    |> assign(:last_updated, page.fetched_at)
    |> drain_queued()
  end

  defp apply_result({:ok, :skipped}, socket) do
    socket |> clear_loading() |> drain_queued()
  end

  # Transient failures flash over rows that are still the last good answer.
  # With nothing on screen they fail the result instead, or the table would
  # sit on its loading text behind a toast.
  defp apply_result({:ok, {:rate_limited, _retry_after_ms}}, socket) do
    socket |> transient_error(:rate_limited, "Too many requests") |> drain_queued()
  end

  defp apply_result({:ok, {:error, :timeout}}, socket) do
    socket |> transient_error(:timeout, "Request timed out") |> drain_queued()
  end

  # A queued replay would hit the same failure; the error on screen is the
  # better answer.
  defp apply_result({:ok, {:error, reason}}, socket) do
    socket |> fail(reason) |> assign(:refetch_queued?, false)
  end

  defp apply_result({:exit, reason}, socket) do
    socket |> fail(reason) |> assign(:refetch_queued?, false)
  end

  defp transient_error(socket, reason, message) do
    if socket.assigns.page_result.ok?,
      do: socket |> clear_loading() |> put_flash(:error, message),
      else: fail(socket, reason)
  end

  defp fail(socket, reason) do
    assign(socket, :page_result, AsyncResult.failed(socket.assigns.page_result, reason))
  end

  defp clear_loading(socket) do
    assign(socket, :page_result, %{socket.assigns.page_result | loading: nil})
  end

  defp drain_queued(socket) do
    if socket.assigns.refetch_queued?, do: fetch(socket), else: socket
  end

  defp start_fetch(socket, priority) do
    %{session: session, controls: controls} = socket.assigns

    # The last result stays assigned, only marked loading, so the table keeps
    # its rows while the fetch runs.
    socket
    |> assign(:refetch_queued?, false)
    |> assign(:page_result, AsyncResult.loading(socket.assigns.page_result))
    |> start_async(:page_result, fn -> run(priority, session.node, controls.timeout) end)
  end

  defp run(priority, node, timeout) do
    started = System.monotonic_time(:millisecond)
    result = RateLimiter.run(priority, fn -> Query.all(node, timeout) end)
    hold_min_duration(started)

    case result do
      {:ok, {:ok, page}, elapsed_us} ->
        {:ok, page, div(elapsed_us, 1_000)}

      {:ok, {:error, reason}, _elapsed_us} ->
        Logger.warning("Failed to list ETS tables on #{inspect(node)}: #{inspect(reason)}")
        {:error, reason}

      # A skipped background refresh is not an error; the next tick retries.
      {:error, :rate_limited, _retry_after_ms} when priority == :low ->
        :skipped

      {:error, :rate_limited, retry_after_ms} ->
        {:rate_limited, retry_after_ms}
    end
  end

  defp hold_min_duration(started) do
    elapsed = System.monotonic_time(:millisecond) - started
    if elapsed < @min_fetch_ms, do: Process.sleep(@min_fetch_ms - elapsed)
  end

  defp restart_refresh_timer(socket) do
    if timer = socket.assigns.refresh_timer, do: Process.cancel_timer(timer)

    case socket.assigns.refresh_interval do
      nil -> assign(socket, :refresh_timer, nil)
      ms -> assign(socket, :refresh_timer, Process.send_after(self(), :auto_refresh, ms))
    end
  end

  # Only a listed value is accepted: a negative delay raises in `send_after/3`
  # and zero would spin.
  defp parse_interval(value) do
    Enum.find_value(@interval_options, fn {_label, option} ->
      option == value && parse_ms(option)
    end)
  end

  defp parse_ms(option) do
    case Integer.parse(option) do
      {ms, ""} -> ms
      _ -> nil
    end
  end
end
