defmodule VoyagerWeb.SupervisionTreeLive do
  use VoyagerWeb, :live_view

  alias Voyager.Queries.SupervisionTree.Remote
  alias Voyager.Services.SupervisionTreeFetch
  alias VoyagerWeb.FormSchemas.SupervisionTreeControls
  alias VoyagerWeb.SupervisionTreeLive.Diff

  @refresh_interval 5_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:active_nav, :supervision_tree)
      |> assign(:available_apps, [])
      |> assign(:available_app_atoms, [])
      |> assign(:selected_apps, MapSet.new())
      |> assign(:depth, SupervisionTreeControls.default_depth())
      |> assign(:expanded_pids, MapSet.new())
      |> assign(:last_tree_flat, nil)
      |> assign(:in_flight, nil)
      |> assign(:errors, [])
      |> assign(:status, :idle)
      |> assign(:refresh_timer, nil)
      |> assign_controls_form()

    socket =
      if connected?(socket) do
        socket
        |> assign_applications()
        |> restart_timer()
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("select-apps", %{"tree_controls" => params}, socket) do
    changeset = SupervisionTreeControls.changeset(params, socket.assigns.available_app_atoms)

    {apps, truncated?} = SupervisionTreeControls.apps_from_changeset(changeset)
    depth = Ecto.Changeset.get_field(changeset, :depth) || socket.assigns.depth

    new_apps = MapSet.new(apps)

    apps_changed? = new_apps != socket.assigns.selected_apps
    depth_changed? = depth != socket.assigns.depth

    socket =
      if truncated? do
        put_flash(
          socket,
          :info,
          "Only #{SupervisionTreeControls.max_apps()} applications can be selected at once."
        )
      else
        socket
      end
      |> assign(:selected_apps, new_apps)
      |> assign(:depth, depth)
      |> assign(:apps_form, to_form(changeset, as: :tree_controls))

    socket =
      if apps_changed? or depth_changed? do
        socket
        |> assign(
          :expanded_pids,
          if(depth_changed?, do: MapSet.new(), else: socket.assigns.expanded_pids)
        )
        |> reset_tree()
        |> request_fetch()
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("toggle-expand", %{"pid" => pid_str}, socket) do
    {expanded, newly_expanded?} =
      toggle_expand(socket, pid_str)

    socket = assign(socket, :expanded_pids, expanded)

    socket =
      if newly_expanded? do
        request_fetch(socket)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("refresh-now", _params, socket) do
    {:noreply, request_fetch(socket)}
  end

  def handle_event("select-node", %{"key" => key}, socket) do
    path = walk_to_root(socket.assigns.last_tree_flat, key)
    {:noreply, push_event(socket, "path-highlight", %{path: path})}
  end

  @impl true
  def handle_info(:refresh, socket) do
    timer = Process.send_after(self(), :refresh, @refresh_interval)
    socket = assign(socket, :refresh_timer, timer)

    socket =
      if MapSet.size(socket.assigns.selected_apps) > 0 and is_nil(socket.assigns.in_flight) do
        request_fetch(socket)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({ref, {status, tree, errors}}, socket) do
    in_flight = socket.assigns.in_flight

    if not is_nil(in_flight) and in_flight.ref == ref do
      Process.demonitor(ref, [:flush])

      new_flat = Diff.flatten(tree)
      prev_flat = socket.assigns.last_tree_flat

      payload =
        case prev_flat do
          nil ->
            %{kind: "full", nodes: new_flat, status: status, errors: errors}

          prev ->
            d = Diff.diff(prev, new_flat)
            Map.merge(d, %{kind: "delta", status: status, errors: errors})
        end

      socket =
        socket
        |> restart_timer()
        |> assign(:errors, errors)
        |> assign(:status, status)
        |> assign(:in_flight, nil)
        |> assign(:last_tree_flat, new_flat)
        |> push_event("tree-data", payload)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, socket) do
    in_flight = socket.assigns.in_flight

    if not is_nil(in_flight) and in_flight.ref == ref do
      socket =
        socket
        |> restart_timer()
        |> assign(:in_flight, nil)
        |> assign(:status, :error)
        |> assign(:errors, socket.assigns.errors ++ [{:fetch, reason}])
        |> reset_tree()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:in_flight] do
      SupervisionTreeFetch.cancel(socket.assigns.in_flight)
    end

    if socket.assigns[:refresh_timer] do
      Process.cancel_timer(socket.assigns.refresh_timer)
    end

    :ok
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-full flex-col gap-4 p-4">
      <%!-- Header --%>
      <div class="card bg-base-100 shadow-sm">
        <div class="card-body flex flex-row items-center gap-4 py-3">
          <div class="flex-1">
            <h1 class="card-title text-base-content">Supervision Tree</h1>
            <p class="text-base-content/60 text-sm">{@session.node_name}</p>
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

      <%!-- Controls --%>
      <div class="card bg-base-100 shadow-sm">
        <div class="card-body py-3">
          <.form
            for={@apps_form}
            id="supervision-tree-controls"
            phx-change="select-apps"
            phx-submit="select-apps"
            class="flex flex-col gap-3"
          >
            <details tabindex="0" class="collapse collapse-arrow">
              <summary class="collapse-title pe-4 ps-12 flex cursor-pointer items-center justify-between after:start-5 after:end-auto">
                <h2 class="text-base-content text-sm font-semibold">Applications</h2>
                <div class="flex items-center gap-2">
                  <label class="label text-base-content/60 text-xs" for={@apps_form[:depth].id}>
                    Depth
                  </label>
                  <.input
                    field={@apps_form[:depth]}
                    type="number"
                    min="1"
                    max="10"
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
                      MapSet.member?(@selected_apps, app) &&
                        "border-primary bg-primary/10 text-primary",
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

      <%!-- Errors --%>
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

      <%!-- Body --%>
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
    </div>
    """
  end

  defp assign_controls_form(socket) do
    changeset =
      SupervisionTreeControls.changeset(
        %{"depth" => socket.assigns.depth},
        socket.assigns.available_app_atoms
      )

    assign(socket, :apps_form, to_form(changeset, as: :tree_controls))
  end

  defp assign_applications(socket) do
    case Remote.list_applications(socket.assigns.session.node) do
      {:ok, apps} ->
        available =
          apps
          |> Enum.map(fn {a, _desc, vsn} -> {a, to_string(vsn)} end)
          |> Enum.sort()

        socket
        |> assign(:available_apps, available)
        |> assign(:available_app_atoms, Enum.map(available, &elem(&1, 0)))
        |> assign_controls_form()

      {:error, reason} ->
        socket
        |> assign(:status, :error)
        |> assign(:errors, [{:list_applications, socket.assigns.session.node, reason}])
    end
  end

  defp restart_timer(socket) do
    if socket.assigns[:refresh_timer] do
      Process.cancel_timer(socket.assigns.refresh_timer)
    end

    timer = Process.send_after(self(), :refresh, @refresh_interval)
    assign(socket, :refresh_timer, timer)
  end

  defp toggle_expand(socket, pid_str) do
    expanded = socket.assigns.expanded_pids
    pid = parse_pid(pid_str)

    cond do
      is_nil(pid) ->
        {expanded, false}

      MapSet.member?(expanded, pid) ->
        {MapSet.delete(expanded, pid), false}

      true ->
        with {:ok, process} <- Map.fetch(socket.assigns.last_tree_flat, pid_str),
             :not_loaded <- process.children_keys do
          {MapSet.put(expanded, pid), true}
        else
          _ -> {expanded, false}
        end
    end
  end

  defp parse_pid(pid_str) when is_binary(pid_str) do
    pid_str |> String.to_charlist() |> :erlang.list_to_pid()
  rescue
    ArgumentError -> nil
  end

  defp parse_pid(_), do: nil

  defp reset_tree(socket), do: assign(socket, :last_tree_flat, nil)

  defp walk_to_root(_flat, ""), do: []
  defp walk_to_root(nil, _key), do: []

  defp walk_to_root(flat, key) when is_map(flat) do
    walk_to_root(flat, key, [])
  end

  defp walk_to_root(_flat, nil, acc), do: Enum.reverse(acc)

  defp walk_to_root(flat, key, acc) do
    case Map.fetch(flat, key) do
      :error -> Enum.reverse(acc)
      {:ok, node} -> walk_to_root(flat, node.parent_key, [key | acc])
    end
  end

  defp request_fetch(socket) do
    if socket.assigns.in_flight do
      SupervisionTreeFetch.cancel(socket.assigns.in_flight)
    end

    selected = MapSet.to_list(socket.assigns.selected_apps)

    if selected == [] do
      socket
      |> assign(:status, :idle)
      |> assign(:in_flight, nil)
      |> reset_tree()
    else
      request = %{
        node: socket.assigns.session.node,
        apps: selected,
        depth: socket.assigns.depth,
        expanded: socket.assigns.expanded_pids
      }

      in_flight = SupervisionTreeFetch.start(request)

      socket
      |> assign(:in_flight, in_flight)
      |> assign(:status, :loading)
    end
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
