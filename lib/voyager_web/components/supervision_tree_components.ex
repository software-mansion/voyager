defmodule VoyagerWeb.Components.SupervisionTreeComponents do
  @moduledoc """
  Components for the supervision tree.
  """

  use VoyagerWeb, :component

  alias VoyagerWeb.FormSchemas.SupervisionTreeControls

  attr :node_name, :string, required: true
  attr :status, :atom, required: true
  attr :last_updated, :any, required: true

  def header(assigns) do
    ~H"""
    <div class="mx-auto w-full">
      <.node_header
        node_name={@node_name}
        last_updated={@last_updated}
        waiting_message="waiting for first fetch…"
      >
        <:actions>
          <span class={["badge", status_badge_class(@status)]}>
            {status_label(@status)}
          </span>
          <button
            type="button"
            phx-click="refresh-now"
            phx-throttle="1000"
            id="supervision-tree-refresh"
            title="Refresh now"
            class="btn btn-sm btn-ghost"
          >
            <.icon
              name="icon-rotate-cw"
              class={["size-4", @status == :loading && "animate-spin"]}
            />
          </button>
        </:actions>
      </.node_header>
    </div>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :available_apps, :list, required: true
  attr :selected_apps, MapSet, required: true
  attr :open?, :boolean, required: true

  def controls(assigns) do
    ~H"""
    <div class="card bg-base-100 border-base-200 border shadow-sm">
      <div class="card-body py-3">
        <.form
          for={@form}
          id="supervision-tree-controls"
          phx-change="select-apps"
          phx-submit="select-apps"
          class="flex items-start"
        >
          <.collapsible id="apps" phx-click="toggle-apps-open" open={@open?} class="flex-1">
            <:label>
              <h2 class="text-base-content ml-2 text-center text-sm font-semibold leading-8">
                Applications
              </h2>
            </:label>
            <div class="flex flex-wrap gap-2 py-4">
              <%= if @available_apps == [] do %>
                <span class="text-base-content/50 text-sm italic">No applications available</span>
              <% else %>
                <%= for {app, vsn} <- @available_apps do %>
                  <label class={[
                    "flex cursor-pointer items-center gap-2 rounded-lg border px-3 py-1.5 text-sm transition-colors",
                    MapSet.member?(@selected_apps, app) && "border-primary bg-primary/10 text-primary",
                    not MapSet.member?(@selected_apps, app) &&
                      "border-base-300 bg-base-200 text-base-content hover:border-primary/50"
                  ]}>
                    <input
                      type="checkbox"
                      name="tree_controls[apps][]"
                      value={to_string(app)}
                      checked={MapSet.member?(@selected_apps, app)}
                      class="checkbox checkbox-xs checkbox-primary"
                    />
                    <span class="font-mono">{app}</span>
                    <span class="badge badge-ghost badge-xs">{vsn}</span>
                  </label>
                <% end %>
              <% end %>
            </div>
          </.collapsible>
          <div class="flex items-start gap-2">
            <label class="label text-base-content/60 text-xs leading-8" for={@form[:depth].id}>
              Depth
            </label>
            <div class="w-20">
              <.input
                field={@form[:depth]}
                type="number"
                step="1"
                min={SupervisionTreeControls.min_depth()}
                class="input-sm text-center"
                phx-debounce="250"
              />
            </div>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  attr :errors, :list, required: true

  def errors(assigns) do
    ~H"""
    <%= if @errors != [] do %>
      <div id="supervision-tree-errors" class="alert alert-error">
        <.icon name="icon-circle-alert" class="size-4 shrink-0" />
        <div class="w-full">
          <p class="font-semibold">Errors encountered</p>
          <ul class="max-h-[10vh] mt-1 w-full list-inside list-disc overflow-auto text-sm">
            <%= for err <- @errors do %>
              <li>{inspect(err)}</li>
            <% end %>
          </ul>
        </div>
      </div>
    <% end %>
    """
  end

  attr :selected_apps, MapSet, required: true
  attr :status, :atom, required: true

  def body(assigns) do
    ~H"""
    <div class="flex-1 overflow-auto">
      <%= cond do %>
        <% MapSet.size(@selected_apps) == 0 -> %>
          <div class="border-base-300 flex h-full flex-col items-center justify-center gap-3 rounded-lg text-center">
            <.icon name="icon-network" class="size-10 text-base-content/30" />
            <div>
              <p class="text-base-content/60 font-medium">No applications selected</p>
              <p class="text-base-content/40 text-sm">
                Select one or more applications to inspect.
              </p>
            </div>
          </div>
        <% @status == :idle -> %>
          <div class="border-base-300 flex h-full flex-col items-center justify-center gap-3 rounded-lg text-center">
            <.icon name="icon-network" class="size-10 text-base-content/30" />
            <div>
              <p class="text-base-content/60 font-medium">Waiting…</p>
            </div>
          </div>
        <% true -> %>
          <div
            id="supervision-tree-body"
            phx-hook="SupervisionTree"
            phx-update="ignore"
            class="bg-base-100 relative h-full overflow-hidden rounded-lg"
          >
            <div
              data-cy-container
              class="absolute inset-0 h-full cursor-grab active:cursor-grabbing"
            >
            </div>
            <div data-cy-overlays class="pointer-events-none absolute inset-0"></div>
            <div class="absolute right-2 bottom-2 left-2 flex items-end justify-between">
              <div class="card bg-base-100 border-base-300 border">
                <div class="card-body font-mono text-base-content/80 flex-row flex-wrap gap-4 px-4 py-3 text-xs">
                  <div>
                    <.icon name="icon-diamond" class="size-4 text-primary" /> App
                  </div>
                  <div>
                    <.icon name="icon-square" class="size-4 text-primary" /> Supervisor
                  </div>
                  <div>
                    <.icon name="icon-circle" class="size-4 text-secondary" /> Worker
                  </div>
                  <div>
                    <.icon name="icon-triangle" class="size-4 text-port" /> Port
                  </div>
                  <div>
                    <.icon name="icon-square" class="size-4 text-success" /> Reference
                  </div>
                  <div class="flex items-center gap-2">
                    <div class="border-base-500 w-4 border-b" /> Supervision link
                  </div>
                  <div class="flex items-center gap-2">
                    <div class="border-base-400 w-4 border-b border-dashed" /> Link
                  </div>
                  <div class="flex items-center gap-2">
                    <div class="border-process-monitor w-4 border-b border-dashed" /> Monitor
                  </div>
                  <div class="flex items-center gap-2">
                    <div class="border-process-monitored-by w-4 border-b border-dashed" />
                    Monitored by
                  </div>
                </div>
              </div>
              <div class="card bg-base-100 border-base-300 m-2 border shadow-md">
                <div class="card-body p-1">
                  <button
                    type="button"
                    phx-click={JS.dispatch("zoom-in", to: "#supervision-tree-body")}
                    title="Zoom graph in"
                    aria-label="Zoom graph in"
                    class="h-8 w-8 cursor-pointer hover:bg-base-300"
                  >
                    <.icon name="icon-plus" class="size-5" />
                  </button>
                  <button
                    type="button"
                    phx-click={JS.dispatch("zoom-out", to: "#supervision-tree-body")}
                    title="Zoom graph out"
                    aria-label="Zoom graph out"
                    class="h-8 w-8 cursor-pointer hover:bg-base-300"
                  >
                    <.icon name="icon-minus" class="size-5" />
                  </button>
                  <button
                    type="button"
                    phx-click={JS.dispatch("maximize", to: "#supervision-tree-body")}
                    title="Fit graph to view"
                    aria-label="Fit graph to view"
                    class="h-8 w-8 cursor-pointer hover:bg-base-300"
                  >
                    <.icon name="icon-maximize" class="size-5" />
                  </button>
                </div>
              </div>
            </div>
          </div>
      <% end %>
    </div>
    """
  end

  defp status_badge_class(:idle), do: "badge-ghost"
  defp status_badge_class(:loading), do: "badge-info"
  defp status_badge_class(:ok), do: "badge-success"
  defp status_badge_class(:partial), do: "badge-warning"
  defp status_badge_class(:error), do: "badge-error"

  defp status_label(:idle), do: "idle"
  defp status_label(:loading), do: "loading"
  defp status_label(:ok), do: "ok"
  defp status_label(:partial), do: "partial"
  defp status_label(:error), do: "error"
end
