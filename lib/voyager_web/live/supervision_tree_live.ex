defmodule VoyagerWeb.SupervisionTreeLive do
  use VoyagerWeb, :live_view

  alias Voyager.Services.SupervisionTree.Fetch
  alias Voyager.Services.SupervisionTree.Remote
  alias VoyagerWeb.Components.SupervisionTreeComponents
  alias VoyagerWeb.FormSchemas.SupervisionTreeControls
  alias VoyagerWeb.SupervisionTreeLive.Diff

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:active_nav, :supervision_tree)
      |> assign(:refresh_interval, SupervisionTreeComponents.default_refresh_interval())
      |> assign(:available_apps, [])
      |> assign(:available_app_atoms, [])
      |> assign(:selected_apps, MapSet.new())
      |> assign(:visible_apps, [])
      |> assign(:search, "")
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
  def handle_params(params, _uri, socket) do
    available = socket.assigns.available_app_atoms

    changeset =
      params
      |> params_to_attrs()
      |> SupervisionTreeControls.changeset(available)

    apps = SupervisionTreeControls.apps_from_changeset(changeset)
    new_selected = MapSet.new(apps)
    depth = Ecto.Changeset.get_field(changeset, :depth) || socket.assigns.depth

    apps_changed? = new_selected != socket.assigns.selected_apps
    depth_changed? = depth != socket.assigns.depth

    {selected_apps, rest_apps} =
      Enum.split_with(socket.assigns.available_apps, fn {app, _} ->
        MapSet.member?(new_selected, app)
      end)

    socket =
      socket
      |> assign(:available_apps, selected_apps ++ rest_apps)
      |> assign(:selected_apps, new_selected)
      |> assign(:depth, depth)
      |> assign(:apps_form, to_form(changeset, as: :tree_controls))
      |> assign_visible_apps()

    socket =
      if connected?(socket) and (apps_changed? or depth_changed?) do
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

  @impl true
  def handle_event("set-interval", %{"interval" => value}, socket) do
    socket
    |> assign(:refresh_interval, parse_interval(value))
    |> stop_timer()
    |> start_timer()
    |> noreply()
  end

  def handle_event("toggle-apps-open", _params, socket) do
    {:noreply, assign(socket, apps_open?: not socket.assigns.apps_open?)}
  end

  def handle_event("select-apps", %{"_target" => ["search"], "search" => search}, socket) do
    socket =
      socket
      |> assign(:search, search)
      |> assign_visible_apps()

    {:noreply, socket}
  end

  def handle_event("select-apps", %{"tree_controls" => params}, socket) do
    changeset =
      params
      |> SupervisionTreeControls.changeset(socket.assigns.available_app_atoms)
      |> Map.put(:action, :validate)

    if changeset.valid? do
      apps = SupervisionTreeControls.apps_from_changeset(changeset)
      depth = Ecto.Changeset.get_field(changeset, :depth)
      {:noreply, push_patch(socket, to: controls_path(socket, apps, depth))}
    else
      {:noreply, assign(socket, :apps_form, to_form(changeset, as: :tree_controls))}
    end
  end

  def handle_event("clear-search", _params, socket) do
    socket =
      socket
      |> assign(:search, "")
      |> assign_visible_apps()

    {:noreply, socket}
  end

  def handle_event("clear-all-apps", _params, socket) do
    socket =
      socket
      |> assign(:available_apps, Enum.sort(socket.assigns.available_apps))
      |> assign(:search, "")

    {:noreply, push_patch(socket, to: controls_path(socket, [], socket.assigns.depth))}
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
        refresh_interval={@refresh_interval}
      />
      <SupervisionTreeComponents.controls
        form={@apps_form}
        available_apps={@available_apps}
        visible_apps={@visible_apps}
        selected_apps={@selected_apps}
        search={@search}
        open?={@apps_open?}
      />
      <SupervisionTreeComponents.errors errors={@errors} />
      <SupervisionTreeComponents.body selected_apps={@selected_apps} status={@status} />
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
    case Remote.list_running_applications(socket.assigns.session.node) do
      {:ok, apps} ->
        available =
          apps
          |> Enum.map(fn {a, _desc, vsn} -> {a, to_string(vsn)} end)
          |> Enum.sort()

        socket
        |> assign(:available_apps, available)
        |> assign(:available_app_atoms, Enum.map(available, &elem(&1, 0)))
        |> assign_visible_apps()
        |> assign_controls_form()

      {:error, reason} ->
        socket
        |> assign(:status, :error)
        |> assign(:errors, [{:list_running_applications, socket.assigns.session.node, reason}])
    end
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

  defp stop_timer(socket) do
    if socket.assigns[:refresh_timer] do
      Process.cancel_timer(socket.assigns.refresh_timer)
    end

    socket
  end

  defp start_timer(socket) do
    case socket.assigns.refresh_interval do
      nil ->
        socket

      interval ->
        timer = Process.send_after(self(), :refresh, interval)
        assign(socket, :refresh_timer, timer)
    end
  end

  defp parse_interval("off"), do: nil

  defp parse_interval(value) do
    case Integer.parse(value) do
      {ms, ""} when ms > 0 -> ms
      _ -> nil
    end
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

  defp controls_path(socket, apps, depth) do
    node = socket.assigns.session.node_name

    query =
      %{"depth" => depth}
      |> maybe_put_apps(apps)

    ~p"/node/#{node}/supervision-tree?#{query}"
  end

  defp maybe_put_apps(query, apps) when apps in [nil, []], do: query

  defp maybe_put_apps(query, apps) do
    Map.put(query, "apps", Enum.map_join(apps, ",", &to_string/1))
  end

  defp params_to_attrs(params) do
    apps =
      case params["apps"] do
        value when is_binary(value) -> String.split(value, ",", trim: true)
        _ -> []
      end

    depth = params["depth"] || SupervisionTreeControls.default_depth()

    %{"apps" => apps, "depth" => depth}
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
end
