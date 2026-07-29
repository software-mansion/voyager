defmodule VoyagerWeb.SettingsLive.TelemetrySettings do
  @moduledoc false
  use VoyagerWeb, :live_component

  alias Voyager.Settings
  alias Voyager.Telemetry

  @impl true
  def update(assigns, socket) do
    socket
    |> assign(assigns)
    |> assign_new(:locked?, fn -> Settings.locked?(:telemetry_enabled) end)
    |> assign_new(:enabled?, fn -> Settings.get(:telemetry_enabled, true) end)
    |> assign_new(:toggle_revision, fn -> 0 end)
    |> ok()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="card bg-base-100 border-base-200 border shadow-sm">
      <div class="card-body gap-4 p-5">
        <div class="flex items-start justify-between gap-4">
          <div>
            <h3 class="text-base-content text-sm font-semibold">Telemetry</h3>
            <p class="text-base-content/60 mt-1 text-sm">
              Voyager collects anonymous usage and diagnostic telemetry to help us improve the product during the closed alpha. No data from your connected BEAM nodes is included.
            </p>
          </div>
          <input
            id="telemetry-toggle"
            type="checkbox"
            class="toggle toggle-primary mt-1"
            aria-label="Toggle anonymous telemetry"
            checked={@enabled?}
            disabled={@locked?}
            data-toggle-revision={@toggle_revision}
            phx-click="toggle"
            phx-target={@myself}
          />
        </div>

        <div :if={@locked?} id="telemetry-locked" class="alert alert-info text-sm">
          <.icon name="icon-circle-alert" class="size-4" />
          <span>
            This value is set in application config, so changes are disabled.
          </span>
        </div>

        <.link
          href={@terms_of_use_url}
          target="_blank"
          rel="noopener noreferrer"
          class="link link-primary self-start text-xs"
        >
          Terms of Use
        </.link>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("toggle", _params, socket) do
    new_value = not socket.assigns.enabled?

    case Telemetry.set_enabled(new_value) do
      {:ok, _setting} ->
        socket
        |> assign(:enabled?, new_value)
        |> noreply()

      {:error, _} ->
        socket
        |> push_flash(:error, "Failed to toggle telemetry")
        |> assign(:toggle_revision, socket.assigns.toggle_revision + 1)
        |> noreply()
    end
  end
end
