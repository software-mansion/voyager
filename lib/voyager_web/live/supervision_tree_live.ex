defmodule VoyagerWeb.SupervisionTreeLive do
  use VoyagerWeb, :live_view

  alias Voyager.Services.SupervisionTree.Fetch
  alias Voyager.Services.SupervisionTree.Remote
  alias VoyagerWeb.Components.SupervisionTreeComponents
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
      |> assign(:apps_open?, true)
      |> assign(:depth, SupervisionTreeControls.default_depth())
      |> assign(:expanded_pids, MapSet.new())
      |> assign(:last_tree_flat, nil)
      |> assign(:last_updated, nil)
      |> assign(:in_flight, nil)
      |> assign(:errors, [])
      |> assign(:status, :idle)
      |> assign(:refresh_timer, nil)
      |> assign_controls_form()

    socket =
      if connected?(socket) do
        socket
        |> assign_applications()
        |> start_timer()
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle-apps-open", _params, socket) do
    {:noreply, assign(socket, apps_open?: not socket.assigns.apps_open?)}
  end

  def handle_event("select-apps", %{"tree_controls" => params}, socket) do
    changeset =
      params
      |> SupervisionTreeControls.changeset(socket.assigns.available_app_atoms)
      |> Map.put(:action, :validate)

    {apps, truncated?} = SupervisionTreeControls.apps_from_changeset(changeset)
    new_apps = MapSet.new(apps)
    apps_changed? = new_apps != socket.assigns.selected_apps

    socket =
      socket
      |> maybe_flash_truncated(truncated?)
      |> assign(:selected_apps, new_apps)
      |> assign(:apps_form, to_form(changeset, as: :tree_controls))

    socket =
      if changeset.valid? do
        apply_valid_controls(socket, changeset, apps_changed?)
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
    socket =
      socket
      |> stop_timer()
      |> start_timer()

    socket =
      if MapSet.size(socket.assigns.selected_apps) > 0 and is_nil(socket.assigns.in_flight) do
        request_fetch(socket)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({ref, {status, result, errors}}, socket) do
    in_flight = socket.assigns.in_flight

    if not is_nil(in_flight) and in_flight.ref == ref do
      stop_timer(socket)

      Process.demonitor(ref, [:flush])

      new_flat = result.nodes
      prev_flat = socket.assigns.last_tree_flat

      payload =
        case prev_flat do
          nil ->
            %{
              kind: "full",
              nodes: new_flat
            }

          prev ->
            prev
            |> Diff.diff(new_flat)
            |> Map.merge(%{kind: "delta"})
        end

      socket =
        socket
        |> assign(:errors, errors)
        |> assign(:status, status)
        |> assign(:in_flight, nil)
        |> assign(:last_tree_flat, new_flat)
        |> assign(:last_updated, DateTime.utc_now())
        |> push_event("tree-data", payload)
        |> start_timer()

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
        |> stop_timer()
        |> start_timer()
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
      Fetch.cancel(socket.assigns.in_flight)
    end

    stop_timer(socket)

    :ok
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-full flex-col gap-4 p-6 sm:p-8">
      <SupervisionTreeComponents.header
        node_name={@session.node_name}
        status={@status}
        last_updated={@last_updated}
      />
      <SupervisionTreeComponents.controls
        form={@apps_form}
        available_apps={@available_apps}
        selected_apps={@selected_apps}
        open?={@apps_open?}
      />
      <SupervisionTreeComponents.errors errors={@errors} />
      <SupervisionTreeComponents.body selected_apps={@selected_apps} status={@status} />
    </div>
    """
  end

  defp apply_valid_controls(socket, changeset, apps_changed?) do
    depth = Ecto.Changeset.get_field(changeset, :depth) || socket.assigns.depth
    depth_changed? = depth != socket.assigns.depth

    socket = assign(socket, :depth, depth)

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
  end

  defp maybe_flash_truncated(socket, false), do: socket

  defp maybe_flash_truncated(socket, true) do
    put_flash(
      socket,
      :info,
      "Only #{SupervisionTreeControls.max_apps()} applications can be selected at once."
    )
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

  defp stop_timer(socket) do
    if socket.assigns[:refresh_timer] do
      Process.cancel_timer(socket.assigns.refresh_timer)
    end

    socket
  end

  defp start_timer(socket) do
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
        {MapSet.put(expanded, pid), true}
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
      Fetch.cancel(socket.assigns.in_flight)
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

      in_flight = Fetch.start(request)

      socket
      |> assign(:in_flight, in_flight)
      |> assign(:status, :loading)
    end
  end
end
