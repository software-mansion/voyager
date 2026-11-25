defmodule VoyagerWeb.ConnectLive.DemoBanner do
  use VoyagerWeb, :live_component

  alias Voyager.Services.DemoNode
  alias VoyagerWeb.ConnectLive.DirectConnect

  @impl true
  def mount(socket) do
    socket
    |> assign(:offer, DemoNode.offer())
    |> assign(:starting?, false)
    |> ok()
  end

  @impl true
  def update(%{refresh: true}, socket) do
    socket
    |> assign(:offer, DemoNode.offer())
    |> ok()
  end

  def update(%{start: true}, socket) do
    socket
    |> start_demo()
    |> ok()
  end

  def update(assigns, socket) do
    socket
    |> assign(assigns)
    |> ok()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <div
        :if={@offer != :hidden}
        id="demo-tab"
        role="note"
        class="border-primary/30 bg-primary/5 rounded-t-box -top-9.5 pb-4.5 absolute left-10 flex items-center gap-2 whitespace-nowrap border-2 pt-1.5 pr-1.5 pl-3 text-xs"
      >
        <.icon :if={not @starting?} name="icon-binoculars" class="text-primary size-4 shrink-0" />
        <span :if={@starting?} class="loading loading-spinner loading-xs text-primary"></span>
        <span class="text-base-content/70">No node at hand?</span>
        <button
          type="button"
          id="start-demo-btn"
          phx-click="start_demo"
          phx-target={@myself}
          disabled={@disabled? or @starting?}
          class="text-primary group inline-flex h-6 cursor-pointer items-center gap-1 rounded font-semibold hover:underline focus-visible:outline-primary focus-visible:underline focus-visible:outline-2 focus-visible:outline-offset-2 disabled:text-base-content/40 disabled:cursor-not-allowed disabled:no-underline"
        >
          Start demo
          <.icon
            name="icon-arrow-right"
            class="size-3.5 transition-transform group-hover:translate-x-0.5 group-disabled:translate-x-0"
          />
        </button>
        <button
          :if={@offer == :dismissible}
          type="button"
          id="dismiss-demo-btn"
          phx-click="dismiss"
          phx-target={@myself}
          title="Dismiss"
          aria-label="Dismiss demo tab"
          class="btn btn-ghost btn-square btn-xs text-base-content/60 hover:text-base-content"
        >
          <.icon name="icon-x" class="size-3.5" />
        </button>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("start_demo", _params, socket) do
    socket
    |> start_demo()
    |> noreply()
  end

  def handle_event("dismiss", _params, socket) do
    case DemoNode.dismiss() do
      :ok ->
        socket
        |> assign(:offer, :hidden)
        |> noreply()

      {:error, _reason} ->
        socket
        |> push_flash(:error, "Could not dismiss the demo tab")
        |> noreply()
    end
  end

  @impl true
  def handle_async(:start_demo, {:ok, {:ok, params}}, socket) do
    send_update(DirectConnect, id: socket.assigns.connect_id, demo: params)

    socket
    |> assign(:starting?, false)
    |> push_flash(:info, "Demo node started. Press Connect to explore it.")
    |> push_patch(to: connect_path(:direct))
    |> noreply()
  end

  def handle_async(:start_demo, _failed, socket) do
    socket
    |> assign(:starting?, false)
    |> push_flash(:error, "Could not start the demo node")
    |> noreply()
  end

  defp start_demo(%{assigns: %{disabled?: false, starting?: false}} = socket) do
    socket
    |> assign(:starting?, true)
    |> start_async(:start_demo, &DemoNode.start/0)
  end

  defp start_demo(socket), do: socket
end
