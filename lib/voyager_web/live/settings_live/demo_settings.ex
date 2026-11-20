defmodule VoyagerWeb.SettingsLive.DemoSettings do
  @moduledoc false
  use VoyagerWeb, :html

  attr :connected?, :boolean, required: true

  def demo_settings(assigns) do
    ~H"""
    <div id="demo-settings" class="card bg-base-100 border-base-200 border shadow-sm">
      <div class="card-body gap-4 p-5">
        <div>
          <h3 class="text-base-content text-sm font-semibold">Demo node</h3>
          <p class="text-base-content/70 mt-1 text-sm">
            Explore Voyager on a bundled demo node.
          </p>
        </div>

        <div :if={@connected?} id="demo-settings-connected" class="alert alert-warning text-sm">
          <.icon name="icon-circle-alert" class="text-warning size-4" />
          <span>Cannot start the demo node when a node is connected.</span>
        </div>

        <div class="card-actions justify-end">
          <.link
            :if={not @connected?}
            id="start-demo-setting"
            href={~p"/?demo=start"}
            class="btn btn-primary"
          >
            <.icon name="icon-binoculars" class="size-4" /> Start demo node
          </.link>
          <button
            :if={@connected?}
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
end
