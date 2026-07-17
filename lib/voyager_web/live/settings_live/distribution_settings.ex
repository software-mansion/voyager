defmodule VoyagerWeb.SettingsLive.DistributionSettings do
  @moduledoc false
  use VoyagerWeb, :live_component

  alias Voyager.Settings
  alias VoyagerWeb.FormSchemas.DistributionSettings, as: DistributionSettingsParams

  require Logger

  @impl true
  def update(assigns, socket) do
    socket
    |> assign(assigns)
    |> assign(:locked?, Settings.locked?(:distribution_suffix))
    |> assign_new(:form, &distribution_settings_form/0)
    |> ok()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="card bg-base-100 border-base-200 border shadow-sm">
      <div class="card-body gap-4 p-5">
        <div>
          <h3 class="text-base-content text-sm font-semibold">Distribution</h3>
          <p class="text-base-content/60 mt-1 text-sm">
            To connect to a remote node, Voyager starts its own distribution named <span class="font-mono font-bold">voyager&lt;suffix&gt;</span>.
            This suffix allows multiple Voyager instances to run on the same network.
            Leave empty to use <span class="font-mono font-bold">voyager</span>.
          </p>
        </div>

        <div
          :if={@connected?}
          id="distribution-settings-connected"
          class="alert alert-warning text-sm"
        >
          <.icon name="icon-circle-alert" class="size-4" />
          <span>Cannot change settings when node is connected.</span>
        </div>

        <div :if={@locked?} id="distribution-settings-locked" class="alert alert-info text-sm">
          <.icon name="icon-circle-alert" class="size-4" />
          <span>
            This value is set in application config, so changes are disabled.
          </span>
        </div>

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
                class="font-mono tracking-label text-base-content/50 flex items-center gap-0.5 text-xs font-semibold uppercase"
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
            <.effective_distribution_name suffix={@form[:distribution_suffix].value} />
          </div>

          <div class="card-actions justify-end">
            <button type="submit" class="btn btn-primary" disabled={@locked? or @connected?}>
              Save suffix
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("validate", %{"distribution_settings" => params}, socket) do
    changeset = DistributionSettingsParams.changeset(params)

    socket
    |> assign(:form, to_form(changeset, as: :distribution_settings))
    |> noreply()
  end

  def handle_event("save", _params, %{assigns: %{connected?: true}} = socket) do
    {:noreply, socket}
  end

  def handle_event("save", %{"distribution_settings" => params}, socket) do
    changeset = DistributionSettingsParams.changeset(params)

    with false <- Settings.locked?(:distribution_suffix),
         {:ok, settings} <- Ecto.Changeset.apply_action(changeset, :insert),
         {:ok, _} <- Settings.put(:distribution_suffix, settings.distribution_suffix) do
      send(self(), {:distribution_settings, :saved})
      {:noreply, socket}
    else
      true ->
        send(self(), {:distribution_settings, :locked})

        socket
        |> assign(:locked?, true)
        |> noreply()

      {:error, %Ecto.Changeset{} = changeset} ->
        socket
        |> assign(:form, to_form(changeset, as: :distribution_settings))
        |> noreply()

      {:error, error} ->
        Logger.error("Failed to save distribution settings: #{inspect(error)}")
        {:noreply, socket}
    end
  end

  attr :suffix, :string, required: true

  defp effective_distribution_name(assigns) do
    assigns = assign(assigns, :name, distribution_name(assigns.suffix))

    ~H"""
    <p class="text-base-content/50 mt-2 text-xs">
      Effective distribution name: <span class="font-mono text-base-content">{@name}</span>
    </p>
    """
  end

  defp distribution_name(""), do: "voyager"
  defp distribution_name(nil), do: "voyager"
  defp distribution_name(suffix), do: "voyager#{suffix}"

  defp distribution_settings_form do
    %{"distribution_suffix" => Settings.get(:distribution_suffix, "")}
    |> DistributionSettingsParams.changeset()
    |> to_form(as: :distribution_settings)
  end
end
