defmodule VoyagerWeb.SettingsLive do
  use VoyagerWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-3xl p-8">
      <div class="mb-8 flex items-center gap-3">
        <button
          id="settings-back-btn"
          phx-hook=".SettingsBack"
          class="btn btn-ghost btn-square btn-sm text-base-content/60 transition-colors hover:text-base-content"
          title="Go back"
        >
          <.icon name="icon-arrow-left" class="size-5" />
        </button>
        <h1 class="text-2xl font-semibold tracking-tight">Settings</h1>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".SettingsBack">
        export default {
          mounted() {
            this.el.addEventListener("click", () => window.history.back())
          }
        }
      </script>
    </div>
    """
  end
end
