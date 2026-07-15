defmodule VoyagerWeb.SettingsLive.AppearanceSettings do
  @moduledoc false
  use VoyagerWeb, :html

  def appearance_settings(assigns) do
    ~H"""
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

                this.onStorage = (e) => {
                  if (e.key === "phx:theme") this.sync()
                }

                this.sync()
                window.addEventListener("phx:set-theme", this.sync)
                window.addEventListener("storage", this.onStorage)
              },
              destroyed() {
                window.removeEventListener("phx:set-theme", this.sync)
                window.removeEventListener("storage", this.onStorage)
              }
            }
          </script>
        </div>
      </div>
    </div>
    """
  end
end
