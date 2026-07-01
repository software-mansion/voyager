defmodule VoyagerWeb.DistributionSettingsLive do
  use VoyagerWeb, :live_component

  alias Voyager.Settings
  alias VoyagerWeb.FormSchemas.DistributionSettings

  require Logger

  @impl true
  def update(%{id: id, connected?: connected?}, socket) do
    {:ok,
     socket
     |> assign(
       id: id,
       connected?: connected?
     )
     |> assign(:locked?, Settings.locked?(:distribution_suffix))
     |> assign_new(:form, &distribution_settings_form/0)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class="bg-base-200/95 fixed inset-0 z-40 flex items-center justify-center p-4 backdrop-blur-sm"
    >
      <div class="card bg-base-100 border-base-300 w-full max-w-lg border shadow-2xl">
        <div class="card-body gap-5 p-8">
          <div class="flex items-start gap-4">
            <div class="bg-primary/10 text-primary rounded-box size-11 flex shrink-0 items-center justify-center">
              <.icon name="icon-settings" class="size-5" />
            </div>
            <div class="min-w-0 flex-1">
              <h2 class="text-base-content text-xl font-semibold tracking-tight">
                Distribution settings
              </h2>
              <p id="distribution-settings-help" class="text-base-content/60 mt-1 text-sm">
                To connect with node Voyager starts distribution using the <span class="font-mono font-bold">voyager&lt;suffix&gt;</span>.
                This suffix allows multiple Voyager instances to run on the same network.
                Leave empty to use <span class="font-mono font-bold">voyager</span>.
              </p>
            </div>
            <button
              type="button"
              id="close-distribution-settings"
              phx-click="close"
              phx-target={@myself}
              title="Close distribution settings"
              class="btn btn-ghost btn-square btn-sm text-base-content/50 hover:text-base-content"
            >
              <.icon name="icon-x" class="size-4" />
            </button>
          </div>

          <%= if @connected? do %>
            <div id="distribution-settings-connected" class="alert alert-warning text-sm">
              <.icon name="icon-circle-alert" class="size-4" />
              <span>Cannot change settings when node is connected.</span>
            </div>
          <% end %>

          <%= if @locked? do %>
            <div id="distribution-settings-locked" class="alert alert-info text-sm">
              <.icon name="icon-circle-alert" class="size-4" />
              <span>
                This value is set in application config, so changes are disabled.
              </span>
            </div>
          <% end %>

          <.form
            for={@form}
            id="distribution-settings-form"
            phx-change="validate"
            phx-submit="save"
            phx-target={@myself}
            class="flex flex-col gap-4"
          >
            <div>
              <div class="mb-1.5 flex items-center gap-2">
                <label
                  class="font-mono tracking-label text-base-content/50 text-xs uppercase"
                  for={@form[:distribution_suffix].id}
                >
                  Distribution name suffix
                </label>
              </div>
              <.input
                field={@form[:distribution_suffix]}
                type="text"
                placeholder="_dev"
                autocomplete="off"
                spellcheck="false"
                disabled={@locked? or @connected?}
                class="font-mono text-sm"
              />
              <p class="text-base-content/50 mt-2 text-xs">
                Effective distribution name:
                <span class="font-mono text-base-content">
                  {"voyager#{@form[:distribution_suffix].value || ""}"}
                </span>
              </p>
            </div>

            <div class="card-actions justify-end">
              <button
                type="button"
                id="cancel-distribution-settings"
                phx-click="close"
                phx-target={@myself}
                class="btn btn-ghost"
              >
                Cancel
              </button>
              <button type="submit" class="btn btn-primary" disabled={@locked? or @connected?}>
                Save settings
              </button>
            </div>
          </.form>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("validate", %{"distribution_settings" => params}, socket) do
    changeset = DistributionSettings.changeset(params)
    {:noreply, assign(socket, :form, to_form(changeset, as: :distribution_settings))}
  end

  def handle_event("close", _, socket) do
    send(self(), {:distribution_settings, :closed})
    {:noreply, socket}
  end

  def handle_event("save", _params, %{assigns: %{connected?: true}} = socket) do
    {:noreply, socket}
  end

  def handle_event("save", %{"distribution_settings" => params}, socket) do
    changeset = DistributionSettings.changeset(params)

    with false <- Settings.locked?(:distribution_suffix),
         {:ok, settings} <- Ecto.Changeset.apply_action(changeset, :insert),
         {:ok, _} <- Settings.put(:distribution_suffix, settings.distribution_suffix) do
      send(self(), {:distribution_settings, :saved})
      {:noreply, socket}
    else
      true ->
        send(self(), {:distribution_settings, :locked})
        {:noreply, assign(socket, :locked?, true)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :distribution_settings))}

      {:error, error} ->
        Logger.error("Failed to save distribution settings: #{inspect(error)}")
        {:noreply, socket}
    end
  end

  defp distribution_settings_form do
    %{"distribution_suffix" => Settings.get(:distribution_suffix, "")}
    |> DistributionSettings.changeset()
    |> to_form(as: :distribution_settings)
  end
end
