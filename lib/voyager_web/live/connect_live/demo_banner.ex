defmodule VoyagerWeb.ConnectLive.DemoBanner do
  use VoyagerWeb, :live_component

  alias Voyager.Services.DemoNode
  alias VoyagerWeb.ConnectLive.DirectConnect

  @impl true
  def mount(socket) do
    socket
    |> assign(:offered?, DemoNode.offered?())
    |> assign(:starting?, false)
    |> ok()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <div
        :if={@offered?}
        role="note"
        class="alert alert-info alert-soft alert-horizontal mb-6 text-xs"
      >
        <.icon name="icon-binoculars" class="text-info size-4 shrink-0" />
        <div>
          <p class="font-semibold">No node at hand?</p>
          <p>Explore Voyager on a bundled demo node.</p>
        </div>
        <div class="flex items-center gap-1">
          <button
            type="button"
            id="start-demo-btn"
            phx-click="start_demo"
            phx-target={@myself}
            disabled={@disabled? or @starting?}
            class="btn btn-info btn-sm gap-1.5"
          >
            <.icon :if={not @starting?} name="icon-play" class="size-3.5" />
            <span :if={@starting?} class="loading loading-spinner loading-xs"></span> Start demo
          </button>
          <button
            type="button"
            id="dismiss-demo-btn"
            phx-click="dismiss"
            phx-target={@myself}
            title="Dismiss"
            aria-label="Dismiss the demo banner"
            class="btn btn-ghost btn-square btn-xs"
          >
            <.icon name="icon-x" class="size-3.5" />
          </button>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event(
        "start_demo",
        _params,
        %{assigns: %{disabled?: false, starting?: false}} = socket
      ) do
    socket
    |> assign(:starting?, true)
    |> start_async(:start_demo, &DemoNode.start/0)
    |> noreply()
  end

  def handle_event("start_demo", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("dismiss", _params, socket) do
    :ok = DemoNode.dismiss()

    socket
    |> assign(:offered?, false)
    |> noreply()
  end

  @impl true
  def handle_async(:start_demo, {:ok, {:ok, params}}, socket) do
    send_update(DirectConnect, id: socket.assigns.connect_id, demo: params)

    socket
    |> assign(:starting?, false)
    |> push_patch(to: connect_path(:direct))
    |> noreply()
  end

  def handle_async(:start_demo, _failed, socket) do
    socket
    |> assign(:starting?, false)
    |> push_flash(:error, "Could not start the demo node")
    |> noreply()
  end
end
