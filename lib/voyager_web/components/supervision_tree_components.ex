defmodule VoyagerWeb.Components.SupervisionTreeComponents do
  @moduledoc """
  Components for the supervision tree.
  """

  use VoyagerWeb, :component

  attr :node_name, :string, required: true
  attr :status, :atom, required: true

  def header(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-sm">
      <div class="card-body flex flex-row items-center gap-4 py-3">
        <div class="flex-1">
          <h1 class="card-title text-base-content">Supervision Tree</h1>
          <p class="text-base-content/60 text-sm">{@node_name}</p>
        </div>
        <div class="flex items-center gap-3">
          <span class={["badge", status_badge_class(@status)]}>
            {status_label(@status)}
          </span>
          <button
            id="supervision-tree-refresh"
            class="btn btn-sm btn-ghost"
            phx-click="refresh-now"
            title="Refresh now"
          >
            <.icon
              name="icon-rotate-cw"
              class={["size-4", @status == :loading && "animate-spin"]}
            />
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :available_apps, :list, required: true
  attr :selected_apps, MapSet, required: true

  def controls(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-sm">
      <div class="card-body py-3">
        <.form
          for={@form}
          id="supervision-tree-controls"
          phx-change="select-apps"
          phx-submit="select-apps"
          class="flex flex-col gap-3"
        >
          <details tabindex="0" class="collapse collapse-arrow">
            <summary class="collapse-title pe-4 ps-12 flex cursor-pointer items-center justify-between after:start-5 after:end-auto">
              <h2 class="text-base-content text-sm font-semibold">Applications</h2>
              <div class="flex items-center gap-2">
                <label class="label text-base-content/60 text-xs" for={@form[:depth].id}>
                  Depth
                </label>
                <.input
                  field={@form[:depth]}
                  type="number"
                  min="1"
                  class="input-sm w-16 text-center"
                />
              </div>
            </summary>
            <div class="collapse-content flex flex-wrap gap-2">
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
          </details>
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
        <div>
          <p class="font-semibold">Errors encountered</p>
          <ul class="mt-1 list-inside list-disc text-sm">
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
          <div class="border-base-300 flex h-full flex-col items-center justify-center gap-3 rounded-lg border border-dashed text-center">
            <.icon name="icon-network" class="size-10 text-base-content/30" />
            <div>
              <p class="text-base-content/60 font-medium">No applications selected</p>
              <p class="text-base-content/40 text-sm">
                Select one or more applications to inspect.
              </p>
            </div>
          </div>
        <% @status == :idle -> %>
          <div class="border-base-300 flex h-full flex-col items-center justify-center gap-3 rounded-lg border border-dashed text-center">
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
            class="bg-base-100 relative h-full overflow-hidden rounded-lg shadow-sm"
          >
            <div
              data-cy-container
              class="absolute inset-0 h-full cursor-grab active:cursor-grabbing"
            >
            </div>
            <div data-cy-overlays class="pointer-events-none absolute inset-0"></div>
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
