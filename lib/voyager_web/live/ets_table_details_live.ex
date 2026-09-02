defmodule VoyagerWeb.EtsTableDetailsLive do
  @moduledoc """
  Details page for one ETS table, reached from the list.

  The path names the table the way `?table=` does on the list: by its name or
  inspect-string. It is resolved against a fresh fetch of the node's tables on
  mount and on every manual refresh, so an unnamed table is only found while
  its reference is live.
  """

  use VoyagerWeb, :live_view

  alias Phoenix.LiveView.AsyncResult
  alias Voyager.Erpc
  alias Voyager.Services.RateLimiter
  alias VoyagerWeb.Components.EtsTableComponents
  alias VoyagerWeb.EtsTablesLive.Query
  alias VoyagerWeb.Formatters

  require Logger

  @impl true
  def mount(%{"table" => table_param}, _session, socket) do
    socket
    |> assign(:active_nav, :ets_tables)
    |> assign(:table_param, table_param)
    |> assign(:table, AsyncResult.loading())
    |> maybe_start_fetch()
    |> ok()
  end

  defp maybe_start_fetch(socket) do
    if connected?(socket), do: start_fetch(socket), else: socket
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto flex h-full max-w-screen-2xl flex-col gap-6 p-6 sm:p-8">
      <div class="flex flex-wrap items-center gap-3">
        <.link
          id="back-to-ets-tables"
          navigate={~p"/node/#{@session.node_name}/ets-tables"}
          class="btn btn-ghost btn-sm gap-2"
        >
          <.icon name="icon-arrow-left" class="size-4" /> ETS tables
        </.link>
        <h1 class="font-mono text-base-content min-w-0 truncate text-lg font-semibold">
          {title(@table, @table_param)}
        </h1>
        <EtsTableComponents.private_badge
          :if={private?(@table)}
          id="ets-table-details-private-badge"
          size={:sm}
        />
        <button
          type="button"
          id="ets-table-details-refresh"
          phx-click="refresh"
          phx-throttle="1000"
          title="Refresh"
          aria-label="Refresh"
          class="btn btn-ghost btn-square toolbar-btn ml-auto"
        >
          <.icon
            name="icon-rotate-cw"
            class={["toolbar-icon", @table.loading && "motion-safe:animate-spin"]}
          />
        </button>
      </div>

      <.async_result :let={table} assign={@table}>
        <:loading>
          <.loading_state id="ets-table-details-loading" message="Fetching table…" />
        </:loading>
        <:failed :let={reason}>
          <.error_state id="ets-table-details-error" message={format_error(reason, @table_param)} />
        </:failed>
        <EtsTableComponents.details
          id="ets-table-details"
          table={table}
          owner_href={~p"/node/#{@session.node_name}/processes/#{Formatters.format_pid(table.owner)}"}
        />
      </.async_result>
    </div>
    """
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    if socket.assigns.table.loading do
      socket
    else
      start_fetch(socket)
    end
    |> noreply()
  end

  @impl true
  def handle_async(:table, {:ok, {:ok, table}}, socket) do
    socket
    |> assign(:table, AsyncResult.ok(socket.assigns.table, table))
    |> noreply()
  end

  # A failed refresh flashes over the metadata still on screen; only with
  # nothing to keep does the page itself say what went wrong.
  def handle_async(:table, {:ok, {:error, reason}}, socket) do
    if socket.assigns.table.ok? do
      socket
      |> assign(:table, %{socket.assigns.table | loading: nil})
      |> put_flash(:error, format_error(reason, socket.assigns.table_param))
    else
      assign(socket, :table, AsyncResult.failed(socket.assigns.table, reason))
    end
    |> noreply()
  end

  def handle_async(:table, {:exit, reason}, socket) do
    socket
    |> assign(:table, AsyncResult.failed(socket.assigns.table, reason))
    |> noreply()
  end

  defp start_fetch(socket) do
    %{session: session, table_param: table_param} = socket.assigns

    socket
    |> assign(:table, AsyncResult.loading(socket.assigns.table))
    |> start_async(:table, fn -> run_fetch(session.node, table_param) end)
  end

  defp run_fetch(node, table_param) do
    fetch = fn -> Query.get(node, table_param, Erpc.default_timeout()) end

    case RateLimiter.run(:high, fetch) do
      {:ok, {:ok, table}, _elapsed_us} ->
        {:ok, table}

      {:ok, {:error, :not_found}, _elapsed_us} ->
        {:error, :not_found}

      {:ok, {:error, reason}, _elapsed_us} ->
        Logger.warning("Failed to fetch ETS table on #{inspect(node)}: #{inspect(reason)}")
        {:error, reason}

      {:error, :rate_limited, _retry_after_ms} ->
        {:error, :rate_limited}
    end
  end

  defp title(%AsyncResult{ok?: true, result: table}, _table_param),
    do: EtsTableComponents.display_name(table)

  defp title(_table, table_param), do: table_param

  defp private?(%AsyncResult{ok?: true, result: %{protection: :private}}), do: true
  defp private?(_table), do: false

  defp format_error(:not_found, table_param),
    do: "No table named #{table_param} was found on the node."

  defp format_error(:timeout, _table_param), do: "Request timed out."
  defp format_error(:noconnection, _table_param), do: "Node is unreachable."

  defp format_error(:rate_limited, _table_param),
    do: "Too many requests. Wait a moment and refresh."

  defp format_error(_reason, _table_param), do: "Failed to fetch the table."
end
