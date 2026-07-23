defmodule VoyagerWeb.SupervisionTreeLive.Controls do
  @moduledoc """
  Controls for the supervision-tree view: searching and selecting applications,
  choosing the walk depth, and toggling whether relation edges are drawn.

  Owns the ephemeral UI state (search text, the collapsible open state, the form
  and the derived list of visible apps). Routed state — the selected apps, the
  depth and the relations toggle — still flows through the URL: this component
  builds the path and calls `push_patch/2`, while the parent LiveView's
  `handle_params/3` validates the URL and triggers fetches.
  """

  use VoyagerWeb, :live_component

  alias VoyagerWeb.FormSchemas.SupervisionTreeControls

  @impl true
  def update(assigns, socket) do
    socket
    |> assign(assigns)
    |> assign_new(:search, fn -> "" end)
    |> assign_new(:apps_open?, fn -> true end)
    |> assign_form()
    |> assign_visible_apps()
    |> ok()
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:apps_errors, Enum.map(assigns.apps_form[:apps].errors, &translate_error(&1)))
      |> assign(:selected_apps_count, MapSet.size(assigns.selected_apps))

    ~H"""
    <div class="card bg-base-100 border-base-200 border shadow-sm">
      <div class="card-body py-3">
        <.form
          for={@apps_form}
          id="supervision-tree-controls"
          phx-target={@myself}
          phx-change="select_apps"
          phx-submit="select_apps"
          class="flex items-start"
        >
          <.collapsible
            id="apps"
            phx-target={@myself}
            phx-click="toggle_apps_open"
            open={@apps_open?}
            class="flex-1"
          >
            <:label>
              <h2 class="text-base-content ml-2 text-center text-sm font-semibold leading-8">
                Applications
              </h2>
              <.tooltip id="selected-apps-number-tip" class="ml-4">
                <div
                  :if={@selected_apps_count > 0}
                  class="border-primary text-primary bg-primary/10 h-6.5 w-7.5 flex items-center justify-center rounded-lg border text-xs font-semibold"
                >
                  <span class="font-mono">{@selected_apps_count}</span>
                </div>
                <:content>
                  Number of selected applications
                </:content>
              </.tooltip>
            </:label>
            <div class="flex gap-4">
              <label
                :if={@available_apps != []}
                class="input mt-2 flex max-w-xs items-center gap-2"
              >
                <.icon name="icon-search" class="size-4 text-base-content/50" />
                <input
                  type="text"
                  id="supervision-tree-search"
                  name="search"
                  value={@search}
                  placeholder="Filter applications…"
                  autocomplete="off"
                  class="grow"
                  phx-debounce="150"
                />
                <button
                  :if={@search != ""}
                  type="button"
                  phx-target={@myself}
                  phx-click="clear_search"
                  title="Clear search"
                  aria-label="Clear search"
                  class="cursor-pointer"
                >
                  <.icon name="icon-x" class="size-4" />
                </button>
              </label>
              <button
                :if={@selected_apps_count > 0}
                type="button"
                id="supervision-tree-clear-apps"
                phx-target={@myself}
                phx-click="clear_all_apps"
                title="Clear all applications"
                aria-label="Clear all applications"
                class="btn btn-soft btn-primary mt-2 gap-2"
              >
                <.icon name="icon-x" class="size-4" />
                <span>Clear all</span>
              </button>
            </div>
            <div class="flex flex-wrap gap-2 py-4">
              <%= cond do %>
                <% @available_apps == [] -> %>
                  <span class="text-base-content/50 text-sm italic">No applications available</span>
                <% @visible_apps == [] -> %>
                  <span class="text-base-content/50 text-sm italic">
                    No applications match your search
                  </span>
                <% true -> %>
                  <%= for {app, vsn} <- @visible_apps do %>
                    <label
                      id={"#{app}-#{vsn}-label"}
                      class={[
                        "flex cursor-pointer items-center gap-2 rounded-lg border px-3 py-1.5 text-sm transition-colors",
                        MapSet.member?(@selected_apps, app) &&
                          "border-primary bg-primary/10 text-primary",
                        not MapSet.member?(@selected_apps, app) &&
                          "border-base-300 bg-base-200 text-base-content hover:border-primary/50"
                      ]}
                    >
                      <input
                        id={"#{app}-#{vsn}-input"}
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
            <div>
              <p
                :for={error <- @apps_errors}
                class="font-mono text-error my-1.5 text-xs"
              >
                {error}
              </p>
            </div>
          </.collapsible>
          <div class="flex items-start gap-6">
            <div class="flex items-start gap-3">
              <label class="label text-base-content/60 text-xs leading-8" for={@apps_form[:depth].id}>
                Depth
              </label>
              <.input
                field={@apps_form[:depth]}
                type="number-stepper"
                step="1"
                min={SupervisionTreeControls.min_depth()}
                phx-debounce="250"
              />
            </div>
            <.tooltip
              id="supervision-tree-relations-tip"
              position="left"
              class="flex items-start gap-3"
            >
              <label
                class="label text-base-content/60 text-xs leading-8"
                for="supervision-tree-relations"
              >
                Relations
              </label>
              <input type="hidden" name="tree_controls[include_relations?]" value="false" />
              <input
                id="supervision-tree-relations"
                type="checkbox"
                name="tree_controls[include_relations?]"
                value="true"
                class="toggle toggle-primary mt-1"
                aria-label="Toggle relation edges"
                checked={@apps_form[:include_relations?].value in [true, "true"]}
                phx-debounce="200"
              />
              <:content>
                Show process relations that are <span class="font-bold">not</span>
                part of the application's <span class="font-bold">base supervision tree</span>
                (custom links and monitors)
              </:content>
            </.tooltip>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("toggle_apps_open", _params, socket) do
    socket
    |> assign(:apps_open?, not socket.assigns.apps_open?)
    |> noreply()
  end

  def handle_event("select_apps", %{"_target" => ["search"], "search" => search}, socket) do
    socket
    |> assign(:search, search)
    |> assign_visible_apps()
    |> noreply()
  end

  def handle_event("select_apps", %{"tree_controls" => params}, socket) do
    params
    |> SupervisionTreeControls.changeset(socket.assigns.available_app_atoms)
    |> Ecto.Changeset.apply_action(:validate)
    |> case do
      {:ok,
       %SupervisionTreeControls{apps: apps, depth: depth, include_relations?: include_relations?}} ->
        socket
        |> assign(:apps_form, to_form(params, as: :tree_controls))
        |> push_patch(to: controls_path(socket, apps, depth, include_relations?))

      {:error, changeset} ->
        assign(socket, :apps_form, to_form(changeset, as: :tree_controls))
    end
    |> noreply()
  end

  def handle_event("clear_search", _params, socket) do
    socket
    |> assign(:search, "")
    |> assign_visible_apps()
    |> noreply()
  end

  def handle_event("clear_all_apps", _params, socket) do
    socket
    |> push_patch(
      to: controls_path(socket, [], socket.assigns.depth, socket.assigns.include_relations?)
    )
    |> noreply()
  end

  defp assign_form(socket) do
    changeset =
      SupervisionTreeControls.changeset(
        %{
          "depth" => socket.assigns.depth,
          "include_relations?" => socket.assigns.include_relations?
        },
        socket.assigns.available_app_atoms
      )

    assign(socket, :apps_form, to_form(changeset, as: :tree_controls))
  end

  defp assign_visible_apps(socket) do
    search = socket.assigns.search
    selected = socket.assigns.selected_apps

    visible =
      Enum.filter(socket.assigns.available_apps, fn {app, _vsn} ->
        MapSet.member?(selected, app) or fuzzy_match?(to_string(app), search)
      end)

    assign(socket, :visible_apps, visible)
  end

  defp controls_path(socket, apps, depth, include_relations?) do
    node = socket.assigns.node_name

    query =
      %{"depth" => depth, "relations" => to_string(include_relations?)}
      |> maybe_put_apps(apps)

    ~p"/node/#{node}/supervision-tree?#{query}"
  end

  defp maybe_put_apps(query, apps) when apps in [nil, []], do: query

  defp maybe_put_apps(query, apps) do
    Map.put(query, "apps", Enum.map_join(apps, ",", &to_string/1))
  end

  defp fuzzy_match?(_str, search) when search in [nil, ""], do: true

  defp fuzzy_match?(str, search) do
    subsequence?(String.downcase(str), String.downcase(search))
  end

  defp subsequence?(_str, ""), do: true
  defp subsequence?("", _search), do: false

  defp subsequence?(<<c::utf8, str::binary>>, <<c::utf8, search::binary>>),
    do: subsequence?(str, search)

  defp subsequence?(<<_c::utf8, str::binary>>, search), do: subsequence?(str, search)

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end
end
