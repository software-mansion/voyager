defmodule VoyagerWeb.SettingsLive.UpdateSettings do
  @moduledoc false
  use VoyagerWeb, :html

  attr :update, :map, default: nil

  def update_settings(assigns) do
    assigns = assign(assigns, :version, Voyager.version())

    ~H"""
    <div id="update-settings" class="card bg-base-100 border-base-200 border shadow-sm">
      <div class="card-body gap-4 p-5">
        <div>
          <h3 class="text-base-content text-sm font-semibold">Updates</h3>
          <p class="text-base-content/70 mt-1 text-sm">
            You are running Voyager <span class="font-mono">v{@version}</span>.
          </p>
        </div>

        <p id="update-status" class={["text-sm", update_status_class(@update)]}>
          {update_status(@update)}
        </p>

        <div class="card-actions justify-end">
          <%= if @update && @update.version && @update.status != :checking do %>
            <button
              type="button"
              id="install-app-update-setting"
              phx-click="install-app-update"
              disabled={@update.status == :installing}
              class="btn btn-primary"
            >
              <span
                :if={@update.status == :installing}
                class="loading loading-spinner loading-xs"
              ></span>
              Install v{@update.version}
            </button>
          <% else %>
            <button
              type="button"
              id="check-app-update"
              phx-click="check-app-update"
              disabled={@update && @update.status == :checking}
              class="btn btn-primary"
            >
              <span
                :if={@update && @update.status == :checking}
                class="loading loading-spinner loading-xs"
              ></span>
              Check for updates
            </button>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp update_status(%{status: :checking}), do: "Checking for updates…"
  defp update_status(%{status: :up_to_date}), do: "Voyager is up to date."
  defp update_status(%{status: :check_failed}), do: "Could not check for updates."
  defp update_status(%{status: :installing}), do: "Installing the update…"
  defp update_status(%{status: :failed}), do: "The update could not be installed."
  defp update_status(%{version: version}), do: "Voyager v#{version} is available."
  defp update_status(nil), do: "Updates are checked when Voyager starts."

  defp update_status_class(%{status: :up_to_date}), do: "text-success"

  defp update_status_class(%{status: status}) when status in [:check_failed, :failed],
    do: "text-error"

  defp update_status_class(_update), do: "text-base-content/70"
end
