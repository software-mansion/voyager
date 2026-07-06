defmodule VoyagerWeb.SettingsLive do
  use VoyagerWeb, :live_view

  alias Voyager.NodeSession
  alias Voyager.Settings
  alias VoyagerWeb.FormSchemas.DistributionSettings

  require Logger

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Voyager.PubSub, NodeSession.topic())
    end

    socket
    |> assign(:return_to, safe_return_to(params["return_to"]))
    |> assign(:connected?, not is_nil(NodeSession.current()))
    |> assign(:locked?, Settings.locked?(:distribution_suffix))
    |> assign(:form, distribution_settings_form())
    |> ok()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto flex w-full max-w-2xl flex-col gap-6 px-6 py-10">
      <div>
        <h1 class="text-base-content text-2xl font-semibold tracking-tight">Settings</h1>
        <p class="text-base-content/60 mt-1 text-sm">
          Configure Voyager's appearance and distribution.
        </p>
      </div>

      <div class="card bg-base-100 border-base-200 border shadow-sm">
        <div class="card-body gap-4 p-5">
          <div>
            <h3 class="text-base-content text-sm font-semibold">Appearance</h3>
            <p class="text-base-content/60 mt-1 text-sm">
              Choose how Voyager looks on this device.
            </p>
          </div>

          <div id="theme-setting" phx-hook=".ThemeSetting" class="join self-start">
            <button
              type="button"
              class="join-item btn"
              data-phx-theme="light"
              phx-click={JS.dispatch("phx:set-theme")}
            >
              <.icon name="icon-sun" class="size-4" /> Light
            </button>
            <button
              type="button"
              class="join-item btn"
              data-phx-theme="dark"
              phx-click={JS.dispatch("phx:set-theme")}
            >
              <.icon name="icon-moon" class="size-4" /> Dark
            </button>
            <button
              type="button"
              class="join-item btn"
              data-phx-theme="system"
              phx-click={JS.dispatch("phx:set-theme")}
            >
              <.icon name="icon-monitor" class="size-4" /> Auto
            </button>
            <script :type={Phoenix.LiveView.ColocatedHook} name=".ThemeSetting">
              export default {
                mounted() {
                  this.sync = () => {
                    const active = localStorage.getItem("phx:theme") || "system"
                    this.el.querySelectorAll("[data-phx-theme]").forEach(btn => {
                      btn.classList.toggle("btn-active", btn.dataset.phxTheme === active)
                    })
                  }
                  this.sync()
                  window.addEventListener("phx:set-theme", this.sync)
                },
                destroyed() {
                  window.removeEventListener("phx:set-theme", this.sync)
                }
              }
            </script>
          </div>
        </div>
      </div>

      <div class="card bg-base-100 border-base-200 border shadow-sm">
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

    socket
    |> assign(:form, to_form(changeset, as: :distribution_settings))
    |> noreply()
  end

  def handle_event("save", _params, %{assigns: %{connected?: true}} = socket) do
    {:noreply, socket}
  end

  def handle_event("save", %{"distribution_settings" => params}, socket) do
    changeset = DistributionSettings.changeset(params)

    with false <- Settings.locked?(:distribution_suffix),
         {:ok, settings} <- Ecto.Changeset.apply_action(changeset, :insert),
         {:ok, _} <- Settings.put(:distribution_suffix, settings.distribution_suffix) do
      socket
      |> put_flash(:info, "Distribution suffix saved")
      |> noreply()
    else
      true ->
        socket
        |> put_flash(:error, "Distribution suffix is controlled by application config")
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

  @impl true
  def handle_info({:node_connected, _node}, socket) do
    socket
    |> assign(:connected?, not is_nil(NodeSession.current()))
    |> noreply()
  end

  def handle_info({event, _node}, socket) when event in [:node_disconnected, :nodedown] do
    socket
    |> assign(:connected?, false)
    |> noreply()
  end

  def handle_info(_, socket), do: {:noreply, socket}

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
    |> DistributionSettings.changeset()
    |> to_form(as: :distribution_settings)
  end

  defp safe_return_to("/" <> _ = path), do: path
  defp safe_return_to(_), do: "/"
end
