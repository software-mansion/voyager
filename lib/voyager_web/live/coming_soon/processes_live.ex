defmodule VoyagerWeb.ComingSoon.ProcessesLive do
  @moduledoc """
  Stands in for the processes page while it is being built, and doubles as the
  harness for the term inspector: it picks the largest process on the node and
  renders its state, process dictionary and mailbox as three independent terms.

  Each read is truncated on the remote before it crosses the wire, so a tile
  can show a partial term; the inspector marks what was elided.
  """

  use VoyagerWeb, :live_view

  on_mount VoyagerWeb.Hooks.TermTreeHook

  alias Phoenix.LiveView.AsyncResult
  alias Voyager.Services.ProcessInfo
  alias Voyager.Services.ProcessList
  alias Voyager.Services.ProcessTerm
  alias VoyagerWeb.Components.TermComponents
  alias VoyagerWeb.Hooks.TermTreeHook

  @timeout 5_000
  @entry_limit 100

  @tiles [
    %{id: :state, title: "State", source: "ProcessTerm.fetch_state/4"},
    %{id: :dictionary, title: "Process dictionary", source: "ProcessInfo.fetch_dictionary/5"},
    %{id: :messages, title: "Mailbox", source: "ProcessTerm.fetch_messages/5"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:active_nav, :processes)
      |> assign(:tiles, @tiles)
      |> assign(:pid, AsyncResult.loading())
      |> assign(:terms, Map.new(@tiles, &{&1.id, AsyncResult.loading()}))

    socket = if connected?(socket), do: fetch(socket), else: socket

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-screen-2xl p-6 sm:p-8">
      <.node_header node_name={@session.node_name}>
        <:actions>
          <.tooltip id="refresh-process-tip" position="bottom">
            <button
              type="button"
              id="refresh-process"
              phx-click="refresh"
              phx-throttle="1000"
              aria-label="Fetch the largest process again"
              class="btn btn-ghost btn-square toolbar-btn"
            >
              <.icon
                name="icon-rotate-cw"
                class={["toolbar-icon", @pid.loading && "motion-safe:animate-spin"]}
              />
            </button>
            <:content>Fetch the largest process again</:content>
          </.tooltip>
        </:actions>
      </.node_header>

      <.loading_state
        :if={@pid.loading}
        id="process-loading"
        message="Looking for the largest process…"
      />

      <.error_state
        :if={@pid.failed}
        id="process-error"
        message={"Could not pick a process: #{inspect(@pid.failed)}"}
      />

      <div :if={@pid.ok?} class="mt-6 flex flex-col gap-4">
        <p class="text-base-content/70 font-mono text-sm">
          Largest process by memory: {inspect(@pid.result)}
        </p>

        <div class="grid grid-cols-1 gap-4 xl:grid-cols-3">
          <.term_tile :for={tile <- @tiles} tile={tile} term={@terms[tile.id]} states={@term_states} />
        </div>
      </div>
    </div>
    """
  end

  attr :tile, :map, required: true
  attr :term, AsyncResult, required: true
  attr :states, :map, required: true

  defp term_tile(assigns) do
    assigns = assign(assigns, :inspector_id, inspector_id(assigns.tile.id))

    ~H"""
    <section id={"tile-#{@tile.id}"} class="card bg-base-100 border-base-300 min-w-0 border shadow-sm">
      <div class="card-body gap-3 p-4">
        <header class="flex items-baseline justify-between gap-2">
          <h2 class="text-base-content text-sm font-medium">{@tile.title}</h2>
          <span class="text-base-content/50 truncate font-mono text-xs">{@tile.source}</span>
        </header>

        <.loading_state :if={@term.loading} id={"#{@inspector_id}-loading"} message="Fetching…" />

        <.error_state
          :if={@term.failed}
          id={"#{@inspector_id}-error"}
          message={inspect(@term.failed)}
        />

        <div :if={@term.ok?} class="flex flex-col gap-2">
          <p :if={@term.ok? && @term.result.total} class="text-base-content/60 text-xs">
            Showing {@term.result.shown} of {@term.result.total}
          </p>
          <div class="overflow-x-auto">
            <TermComponents.term_inspector
              id={@inspector_id}
              term={@term.result.term}
              truncated?={@term.result.truncated?}
              state={@states[@inspector_id]}
            />
          </div>
        </div>
      </div>
    </section>
    """
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    socket |> fetch() |> noreply()
  end

  @impl true
  def handle_async(:pid, {:ok, {:ok, pid}}, socket) do
    socket
    |> assign(:pid, AsyncResult.ok(socket.assigns.pid, pid))
    |> fetch_terms(pid)
    |> noreply()
  end

  def handle_async(:pid, {:ok, {:error, reason}}, socket) do
    socket
    |> assign(:pid, AsyncResult.failed(socket.assigns.pid, reason))
    |> noreply()
  end

  def handle_async(:pid, {:exit, reason}, socket) do
    socket
    |> assign(:pid, AsyncResult.failed(socket.assigns.pid, {:exit, reason}))
    |> noreply()
  end

  def handle_async(tile_id, {:ok, {:ok, result}}, socket) do
    socket
    |> put_term(tile_id, &AsyncResult.ok(&1, result))
    |> TermTreeHook.put_term(inspector_id(tile_id), result.term)
    |> noreply()
  end

  def handle_async(tile_id, {:ok, {:error, reason}}, socket) do
    socket |> put_term(tile_id, &AsyncResult.failed(&1, reason)) |> noreply()
  end

  def handle_async(tile_id, {:exit, reason}, socket) do
    socket |> put_term(tile_id, &AsyncResult.failed(&1, {:exit, reason})) |> noreply()
  end

  defp fetch(socket) do
    node = socket.assigns.session.node

    socket
    |> cancel_async(:pid, {:shutdown, :cancel})
    |> assign(:pid, AsyncResult.loading(socket.assigns.pid))
    |> start_async(:pid, fn -> largest_process(node) end)
  end

  defp fetch_terms(socket, pid) do
    node = socket.assigns.session.node

    Enum.reduce(@tiles, socket, fn %{id: id}, acc ->
      acc
      |> cancel_async(id, {:shutdown, :cancel})
      |> put_term(id, &AsyncResult.loading/1)
      |> start_async(id, fn -> fetch_term(node, pid, id) end)
    end)
  end

  defp put_term(socket, tile_id, fun) do
    update(socket, :terms, &Map.update!(&1, tile_id, fun))
  end

  defp largest_process(node) do
    case ProcessList.top(node, [:memory], :memory, 1, @timeout) do
      {:ok, {[%{pid: pid} | _rest], _total}} -> {:ok, pid}
      {:ok, {[], _total}} -> {:error, :no_processes}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_term(node, pid, :state) do
    with {:ok, state} <- ProcessTerm.fetch_state(node, pid) do
      {:ok, %{term: state.term, truncated?: state.truncated?, shown: nil, total: nil}}
    end
  end

  defp fetch_term(node, pid, :dictionary) do
    node
    |> ProcessInfo.fetch_dictionary(pid, @entry_limit)
    |> from_bounded()
  end

  defp fetch_term(node, pid, :messages) do
    node
    |> ProcessTerm.fetch_messages(pid, @entry_limit)
    |> from_bounded()
  end

  defp from_bounded({:ok, bounded}) do
    {:ok,
     %{
       term: bounded.items,
       truncated?: bounded.truncated?,
       shown: length(bounded.items),
       total: bounded.total
     }}
  end

  defp from_bounded({:error, _reason} = error), do: error

  defp inspector_id(tile_id), do: "process-#{tile_id}"
end
