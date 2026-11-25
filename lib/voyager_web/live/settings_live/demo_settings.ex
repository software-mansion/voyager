defmodule VoyagerWeb.SettingsLive.DemoSettings do
  @moduledoc false
  use VoyagerWeb, :html

  alias Voyager.NodeSession.Session
  alias Voyager.Services.DemoNode

  attr :session, Session, default: nil
  attr :running?, :boolean, required: true

  def demo_settings(assigns) do
    assigns = assign(assigns, :status, status(assigns.session, assigns.running?))

    ~H"""
    <div id="demo-settings" class="card bg-base-100 border-base-200 border shadow-sm">
      <div class="card-body gap-4 p-5">
        <div>
          <h3 class="text-base-content text-sm font-semibold">Demo node</h3>
          <p class="text-base-content/70 mt-1 text-sm">
            Explore Voyager on a bundled demo node.
          </p>
        </div>

        <div
          :if={@status in [:running, :connected]}
          id={"demo-settings-#{@status}"}
          class={[
            "flex items-center justify-between gap-3 rounded-lg border px-3.5 py-2.5",
            box_class(@status)
          ]}
        >
          <div class="flex min-w-0 items-center gap-2">
            <span class="size-2 relative flex shrink-0">
              <span class={[
                "size-full absolute inline-flex animate-ping rounded-full opacity-60",
                dot_class(@status)
              ]}></span>
              <span class={["size-2 relative inline-flex rounded-full", dot_class(@status)]}></span>
            </span>
            <span :if={@status == :running} class="text-base-content/75 text-sm">
              The demo node is running. You can restart it here.
            </span>
            <span :if={@status == :connected} class="text-base-content/75 text-sm">
              You are connected to the demo node.
            </span>
          </div>
          <.link
            :if={@status == :running}
            id="start-demo-setting"
            href={~p"/?demo=start"}
            class="btn btn-primary btn-sm shrink-0"
          >
            <.icon name="icon-rotate-cw" class="size-4" /> Restart demo node
          </.link>
        </div>

        <div :if={@status == :blocked} id="demo-settings-blocked" class="alert alert-warning text-sm">
          <.icon name="icon-circle-alert" class="text-warning size-4" />
          <span>Cannot start the demo node when a node is connected.</span>
        </div>

        <div :if={@status in [:stopped, :blocked]} class="card-actions justify-end">
          <.link
            :if={@status == :stopped}
            id="start-demo-setting"
            href={~p"/?demo=start"}
            class="btn btn-primary"
          >
            <.icon name="icon-binoculars" class="size-4" /> Start demo node
          </.link>
          <button
            :if={@status == :blocked}
            type="button"
            id="start-demo-setting"
            disabled
            class="btn btn-primary"
          >
            <.icon name="icon-binoculars" class="size-4" /> Start demo node
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp status(nil, true), do: :running
  defp status(nil, false), do: :stopped

  defp status(%Session{node_name: node_name}, _running?) do
    if node_name == DemoNode.node_name(), do: :connected, else: :blocked
  end

  defp box_class(:running), do: "bg-info-bg border-info"
  defp box_class(:connected), do: "bg-success-bg border-success"

  defp dot_class(:running), do: "bg-info"
  defp dot_class(:connected), do: "bg-success"
end
