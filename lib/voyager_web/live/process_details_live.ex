defmodule VoyagerWeb.ProcessDetailsLive do
  @moduledoc """
  Details for a single process, reached from the process list.

  A pid can die and be reused between the list scan and this drill-in, so the
  page reports a dead or malformed pid explicitly rather than rendering details
  for whatever now holds that pid.
  """

  use VoyagerWeb, :live_view

  import VoyagerWeb.Components.DetailsPanelComponents

  alias Phoenix.LiveView.AsyncResult
  alias Voyager.Queries.Processes

  require Logger

  @impl true
  def mount(%{"pid" => pid_string}, _session, socket) do
    socket =
      socket
      |> assign(:active_nav, :processes)
      |> assign(:pid_string, pid_string)
      |> assign(:pid, nil)
      |> assign(:info, AsyncResult.loading())

    case Processes.parse_pid(pid_string) do
      {:ok, pid} ->
        socket = assign(socket, :pid, pid)

        if connected?(socket) do
          fetch(socket)
        else
          socket
        end

      :error ->
        assign(socket, :info, AsyncResult.failed(socket.assigns.info, :not_a_pid))
    end
    |> ok()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto flex h-full max-w-screen-2xl flex-col gap-4 p-6 sm:p-8">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div class="flex min-w-0 items-center gap-3">
          <.link
            id="back-to-processes"
            navigate={~p"/node/#{@session.node_name}/processes"}
            class="btn btn-ghost btn-sm gap-2"
          >
            <.icon name="icon-arrow-left" class="size-4" /> Processes
          </.link>
          <h1 class="font-mono text-base-content truncate text-lg font-semibold">
            {@pid_string}
          </h1>
        </div>

        <button
          :if={@pid}
          type="button"
          id="refresh-process-info"
          phx-click="refresh"
          phx-throttle="1000"
          aria-label="Refresh process information"
          class="btn btn-ghost btn-square toolbar-btn"
        >
          <.icon
            name="icon-rotate-cw"
            class={["toolbar-icon", @info.loading && "motion-safe:animate-spin"]}
          />
        </button>
      </div>

      <.async_result :let={info} assign={@info}>
        <:loading>
          <.loading_state id="process-details-loading" message="Fetching process information…" />
        </:loading>
        <:failed :let={reason}>
          <.error_state id="process-details-error" message={format_error(reason)} />
        </:failed>

        <div class="grid gap-5 lg:grid-cols-2">
          <div class="border-base-300 bg-base-100 rounded-lg border p-5">
            <.overview info={AsyncResult.ok(info)} />
          </div>
          <div class="border-base-300 bg-base-100 rounded-lg border p-5">
            <.memory_and_garbage_collection info={AsyncResult.ok(info)} />
          </div>
        </div>
      </.async_result>
    </div>
    """
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    socket
    |> fetch()
    |> noreply()
  end

  @impl true
  def handle_async(:info, {:ok, {:ok, %{info: info}}}, socket) do
    socket
    |> assign(:info, AsyncResult.ok(socket.assigns.info, info))
    |> noreply()
  end

  def handle_async(:info, {:ok, {:error, reason}}, socket) do
    socket
    |> assign(:info, AsyncResult.failed(socket.assigns.info, reason))
    |> noreply()
  end

  def handle_async(:info, {:exit, reason}, socket) do
    socket
    |> assign(:info, AsyncResult.failed(socket.assigns.info, reason))
    |> noreply()
  end

  defp fetch(socket) do
    %{session: session, pid: pid} = socket.assigns

    socket
    |> assign(:info, AsyncResult.loading())
    |> assign_async(:info, fn ->
      case Processes.info(session.node, pid) do
        {:ok, info} ->
          {:ok, %{info: info}}

        {:error, reason} ->
          Logger.warning(
            "Failed to load process info for #{inspect(session.node)}/#{inspect(pid)}: " <>
              inspect(reason)
          )

          {:error, reason}
      end
    end)
  end

  defp format_error(:not_a_pid), do: "That is not a valid process identifier."
  defp format_error(:dead), do: "This process is no longer alive."
  defp format_error(:incomplete), do: "Process information was incomplete."
  defp format_error(:timeout), do: "Timed out while fetching process information."
  defp format_error(:noconnection), do: "Node is unreachable."
  defp format_error(_reason), do: "Failed to load process information."
end
