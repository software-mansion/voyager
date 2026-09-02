defmodule VoyagerWeb.ComingSoon.ProcessesLive do
  @moduledoc """
  Stands in for the processes page while it is being built, and doubles as the
  harness for the term inspector: it takes the largest process on the node and
  renders everything `Voyager.Services.ProcessInfo` knows about it as an
  expandable term.
  """

  use VoyagerWeb, :live_view

  on_mount VoyagerWeb.Hooks.TermTreeHook

  alias Phoenix.LiveView.AsyncResult
  alias Voyager.Services.ProcessInfo
  alias Voyager.Services.ProcessList
  alias VoyagerWeb.Components.TermComponents
  alias VoyagerWeb.Hooks.TermTreeHook

  @inspector_id "process-term"
  @timeout 5_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:active_nav, :processes)
      |> assign(:inspector_id, @inspector_id)
      |> assign(:process, AsyncResult.loading())

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
                class={["toolbar-icon", @process.loading && "motion-safe:animate-spin"]}
              />
            </button>
            <:content>Fetch the largest process again</:content>
          </.tooltip>
        </:actions>
      </.node_header>

      <.loading_state
        :if={@process.loading}
        id="process-loading"
        message="Fetching the largest process…"
      />

      <.error_state
        :if={@process.failed}
        id="process-error"
        message={"Could not fetch the process: #{inspect(@process.failed)}"}
      />

      <.info_section :if={@process.ok?} title={"Process info — #{inspect(@process.result.pid)}"}>
        <TermComponents.term_inspector
          id={@inspector_id}
          term={@process.result.info}
          state={@term_states[@inspector_id]}
        />
      </.info_section>
    </div>
    """
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    socket |> fetch() |> noreply()
  end

  @impl true
  def handle_async(:process, {:ok, {:ok, process}}, socket) do
    socket
    |> assign(:process, AsyncResult.ok(socket.assigns.process, process))
    |> TermTreeHook.put_term(@inspector_id, process.info)
    |> noreply()
  end

  def handle_async(:process, {:ok, {:error, reason}}, socket) do
    socket
    |> assign(:process, AsyncResult.failed(socket.assigns.process, reason))
    |> noreply()
  end

  def handle_async(:process, {:exit, reason}, socket) do
    socket
    |> assign(:process, AsyncResult.failed(socket.assigns.process, {:exit, reason}))
    |> noreply()
  end

  defp fetch(socket) do
    node = socket.assigns.session.node

    socket
    |> cancel_async(:process, {:shutdown, :cancel})
    |> assign(:process, AsyncResult.loading(socket.assigns.process))
    |> start_async(:process, fn -> largest_process(node) end)
  end

  defp largest_process(node) do
    with {:ok, {[%{pid: pid} | _rest], _total}} <-
           ProcessList.top(node, [:memory], :memory, 1, @timeout),
         {:ok, info} <- ProcessInfo.fetch(node, pid) do
      {:ok, %{pid: pid, info: info}}
    else
      {:ok, {[], _total}} -> {:error, :no_processes}
      {:error, reason} -> {:error, reason}
    end
  end
end
