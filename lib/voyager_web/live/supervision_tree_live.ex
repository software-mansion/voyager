defmodule VoyagerWeb.SupervisionTreeLive do
  use VoyagerWeb, :live_view

  alias Voyager.Inspector.Fetch
  alias Voyager.Inspector.Remote
  alias Voyager.Node

  @refresh_interval 5_000
  @max_selected_apps 20
  @default_depth 3

  # ---------------------------------------------------------------------------
  # Mount
  # ---------------------------------------------------------------------------

  @impl true
  def mount(%{"node" => node_str}, _session, socket) do
    node_atom =
      try do
        String.to_existing_atom(node_str)
      rescue
        ArgumentError -> nil
      end

    if is_nil(node_atom) do
      {:ok, push_navigate(socket, to: ~p"/")}
    else
      voyager_node = %Node{name: node_atom, status: :connected, connected_at: nil, cookie: nil}

      socket =
        socket
        |> assign(:node, voyager_node)
        |> assign(:active_nav, :supervision_tree)
        |> assign(:available_apps, [])
        |> assign(:selected_apps, MapSet.new())
        |> assign(:depth, @default_depth)
        |> assign(:expanded_pids, MapSet.new())
        |> assign(:tree, nil)
        |> assign(:in_flight, nil)
        |> assign(:errors, [])
        |> assign(:status, :idle)
        |> assign(:last_refreshed_at, nil)
        |> assign(:refresh_timer, nil)
        |> assign(:apps_form, to_form(%{}, as: :tree_controls))

      socket =
        if connected?(socket) do
          socket =
            case Remote.list_applications(node_atom) do
              {:ok, apps} ->
                available =
                  apps
                  |> Enum.map(fn {a, _desc, vsn} -> {a, to_string(vsn)} end)
                  |> Enum.sort()

                assign(socket, :available_apps, available)

              {:error, reason} ->
                socket
                |> assign(:status, :error)
                |> assign(:errors, [{:list_applications, node_atom, reason}])
            end

          timer = Process.send_after(self(), :refresh, @refresh_interval)
          assign(socket, :refresh_timer, timer)
        else
          socket
        end

      {:ok, socket}
    end
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("select-apps", params, socket) do
    # Form uses `as: :tree_controls` so params are nested under "tree_controls"
    inner = Map.get(params, "tree_controls", params)

    app_strings = Map.get(inner, "apps", [])
    app_strings = if is_list(app_strings), do: app_strings, else: [app_strings]

    apps =
      app_strings
      |> Enum.flat_map(fn s ->
        try do
          [String.to_existing_atom(s)]
        rescue
          ArgumentError -> []
        end
      end)

    {apps, truncated?} =
      if length(apps) > @max_selected_apps do
        {Enum.take(apps, @max_selected_apps), true}
      else
        {apps, false}
      end

    socket =
      if truncated? do
        put_flash(
          socket,
          :info,
          "Only #{@max_selected_apps} applications can be selected at once."
        )
      else
        socket
      end

    depth_str = Map.get(inner, "depth", to_string(@default_depth))

    depth =
      case Integer.parse(depth_str) do
        {d, ""} -> d |> max(1) |> min(10)
        _ -> socket.assigns.depth
      end

    socket =
      socket
      |> assign(:selected_apps, MapSet.new(apps))
      |> assign(:depth, depth)

    {:noreply, request_fetch(socket)}
  end

  def handle_event("set-depth", %{"depth" => depth_str}, socket) do
    depth =
      case Integer.parse(depth_str) do
        {d, ""} -> d |> max(1) |> min(10)
        _ -> socket.assigns.depth
      end

    socket = assign(socket, :depth, depth)
    {:noreply, request_fetch(socket)}
  end

  def handle_event("toggle-expand", %{"pid" => pid_str}, socket) do
    pid =
      try do
        # pid_str is stored without angle brackets (e.g. "0.123.0"),
        # but :erlang.list_to_pid/1 requires the "<X.Y.Z>" format.
        full_str = "<#{pid_str}>"
        full_str |> String.to_charlist() |> :erlang.list_to_pid()
      rescue
        _ -> nil
      catch
        _, _ -> nil
      end

    if is_nil(pid) do
      {:noreply, socket}
    else
      expanded = socket.assigns.expanded_pids

      {expanded, newly_expanded?} =
        if MapSet.member?(expanded, pid) do
          {MapSet.delete(expanded, pid), false}
        else
          {MapSet.put(expanded, pid), true}
        end

      socket = assign(socket, :expanded_pids, expanded)

      socket =
        if newly_expanded? do
          request_fetch(socket)
        else
          socket
        end

      {:noreply, socket}
    end
  end

  def handle_event("refresh-now", _params, socket) do
    {:noreply, request_fetch(socket)}
  end

  # ---------------------------------------------------------------------------
  # Info
  # ---------------------------------------------------------------------------

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

      socket =
        socket
        |> assign(:tree, tree)
        |> assign(:errors, errors)
        |> assign(:status, status)
        |> assign(:last_refreshed_at, DateTime.utc_now())
        |> assign(:in_flight, nil)
        |> push_event("tree-data", %{
          tree: serialize_tree(tree),
          status: status,
          errors: serialize_errors(errors)
        })

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
        |> assign(:in_flight, nil)
        |> assign(:status, :error)
        |> assign(:errors, socket.assigns.errors ++ [{:fetch, reason}])

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Terminate
  # ---------------------------------------------------------------------------

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:in_flight] do
      Fetch.cancel(socket.assigns.in_flight)
    end

    if socket.assigns[:refresh_timer] do
      Process.cancel_timer(socket.assigns.refresh_timer)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns, :view_tree, build_view_tree(assigns.tree, assigns.expanded_pids))

    ~H"""
    <div class="flex h-full flex-col gap-4 p-4">
      <%!-- Header --%>
      <div class="card bg-base-100 shadow-sm">
        <div class="card-body flex flex-row items-center gap-4 py-3">
          <div class="flex-1">
            <h1 class="card-title text-base-content">Supervision Tree</h1>
            <p class="text-base-content/60 text-sm">{@node.name}</p>
          </div>
          <div class="flex items-center gap-3">
            <span class={["badge", status_badge_class(@status)]}>
              {status_label(@status)}
            </span>
            <%= if @last_refreshed_at do %>
              <span class="text-base-content/50 text-xs">
                refreshed {relative_time(@last_refreshed_at)}
              </span>
            <% end %>
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
            class="flex flex-col gap-3"
          >
            <div class="flex items-center justify-between">
              <h2 class="text-base-content text-sm font-semibold">Applications</h2>
              <div class="flex items-center gap-2">
                <label class="label text-base-content/60 text-xs" for="depth-input">Depth</label>
                <input
                  id="depth-input"
                  type="number"
                  name="depth"
                  min="1"
                  max="10"
                  value={@depth}
                  class="input input-sm input-bordered w-16 text-center"
                />
              </div>
            </div>
            <div class="flex flex-wrap gap-2">
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
                      name="apps[]"
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
            <div class="border-base-300 flex h-64 flex-col items-center justify-center gap-3 rounded-lg border border-dashed text-center">
              <.icon name="icon-network" class="size-10 text-base-content/30" />
              <div>
                <p class="text-base-content/60 font-medium">No applications selected</p>
                <p class="text-base-content/40 text-sm">
                  Select one or more applications to inspect.
                </p>
              </div>
            </div>
          <% @status == :loading and is_nil(@tree) -> %>
            <div class="text-base-content/50 flex h-64 items-center justify-center gap-3">
              <.icon name="icon-rotate-cw" class="size-6 animate-spin" />
              <span>Loading supervision tree…</span>
            </div>
          <% true -> %>
            <div id="supervision-tree-body" class="bg-base-100 rounded-lg shadow-sm">
              <ul class="space-y-1 p-4">
                <%= for {_app, view_node} <- @view_tree do %>
                  <.tree_node node={view_node} />
                <% end %>
              </ul>
            </div>
        <% end %>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Tree node component
  # ---------------------------------------------------------------------------

  attr :node, :map, required: true

  defp tree_node(assigns) do
    ~H"""
    <li id={@node.dom_id} class="list-none">
      <div class={[
        "flex items-center gap-2 rounded-md px-2 py-1.5 transition-colors",
        @node.dead? && "opacity-50",
        not @node.dead? && "hover:bg-base-200"
      ]}>
        <%!-- Expand toggle --%>
        <div class="flex w-5 shrink-0 items-center justify-center">
          <%= if @node.has_children? do %>
            <button
              class="btn btn-ghost btn-xs h-5 min-h-0 w-5 p-0"
              phx-click="toggle-expand"
              phx-value-pid={@node.pid_str}
            >
              <%= if @node.expanded? do %>
                <.icon name="icon-chevron-down" class="size-3.5" />
              <% else %>
                <.icon name="icon-chevron-right" class="size-3.5" />
              <% end %>
            </button>
          <% else %>
            <span class="w-3.5"></span>
          <% end %>
        </div>

        <%!-- Badge + name + info --%>
        <span class={["badge badge-xs shrink-0", @node.kind_badge]}>
          {badge_label(@node.type)}
        </span>
        <span class={[
          "font-mono flex-1 truncate text-sm",
          @node.dead? && "text-base-content/40 line-through"
        ]}>
          {@node.name}
        </span>
        <span class="text-base-content/40 shrink-0 text-xs">{@node.info_line}</span>
      </div>

      <%!-- Children --%>
      <%= if @node.expanded? and @node.children != [] do %>
        <ul class="border-base-300 mt-0.5 ml-5 space-y-0.5 border-l pl-2">
          <%= for child <- @node.children do %>
            <.tree_node node={child} />
          <% end %>
        </ul>
      <% end %>

      <%!-- Stub indicator --%>
      <%= if @node.stub? and not @node.expanded? and @node.has_children? do %>
        <div class="text-base-content/30 ml-12 text-xs italic">
          — click to expand
        </div>
      <% end %>
    </li>
    """
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp request_fetch(socket) do
    if socket.assigns.in_flight do
      Fetch.cancel(socket.assigns.in_flight)
    end

    selected = MapSet.to_list(socket.assigns.selected_apps)

    if selected == [] do
      socket
      |> assign(:status, :idle)
      |> assign(:tree, nil)
      |> assign(:in_flight, nil)
    else
      request = %{
        node: socket.assigns.node.name,
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

  defp build_view_tree(nil, _expanded_pids), do: []

  defp build_view_tree(tree, expanded_pids) do
    Enum.map(tree, fn {app, node} ->
      {app, to_view_node(node, expanded_pids)}
    end)
  end

  defp to_view_node(node, expanded_pids) do
    pid_str = pid_string(node.pid)
    expanded? = not is_nil(node.pid) and MapSet.member?(expanded_pids, node.pid)
    name_str = node_name_to_string(node.name)

    dom_id =
      if node.pid do
        "tree-node-#{pid_dom_id(node.pid)}"
      else
        "tree-node-name-#{name_str}"
      end

    children =
      case node.children do
        :not_loaded -> []
        list when is_list(list) -> Enum.map(list, &to_view_node(&1, expanded_pids))
      end

    %{
      dom_id: dom_id,
      name: name_str,
      pid_str: pid_str,
      type: node.type,
      info_line: build_info_line(node.info),
      kind_badge: kind_badge_class(node.type, node.info),
      dead?: node.info == :dead,
      expanded?: expanded?,
      stub?: node.children == :not_loaded,
      has_children?: node.has_children?,
      children: children
    }
  end

  defp build_info_line(nil), do: ""
  defp build_info_line(:dead), do: "dead"

  defp build_info_line(info) when is_map(info) do
    mem = format_memory(Map.get(info, :memory))
    mq = Map.get(info, :message_queue_len, 0)
    "#{mem} | mq: #{mq}"
  end

  defp kind_badge_class(:app, _), do: "badge-primary"
  defp kind_badge_class(:supervisor, :dead), do: "badge-error"
  defp kind_badge_class(:supervisor, _), do: "badge-secondary"
  defp kind_badge_class(:worker, :dead), do: "badge-error"
  defp kind_badge_class(:worker, _), do: "badge-ghost"

  defp badge_label(:app), do: "app"
  defp badge_label(:supervisor), do: "sup"
  defp badge_label(:worker), do: "wkr"

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

  defp node_name_to_string(name) when is_atom(name), do: to_string(name)
  defp node_name_to_string(name) when is_binary(name), do: name
  defp node_name_to_string(name), do: inspect(name)

  defp pid_string(nil), do: "nil"

  defp pid_string(pid) when is_pid(pid) do
    # Strip angle brackets so the string is safe for use in HTML attrs.
    # :erlang.pid_to_list produces e.g. "<0.123.0>"; we return "0.123.0".
    pid
    |> :erlang.pid_to_list()
    |> List.to_string()
    |> String.trim_leading("<")
    |> String.trim_trailing(">")
  end

  # DOM-safe version: replace dots with dashes so CSS id selectors work.
  # "0.123.0" -> "0-123-0"
  defp pid_dom_id(nil), do: "nil"
  defp pid_dom_id(pid) when is_pid(pid), do: pid |> pid_string() |> String.replace(".", "-")

  defp format_memory(nil), do: "—"
  defp format_memory(0), do: "0 B"

  defp format_memory(bytes) when bytes < 1024 do
    "#{bytes} B"
  end

  defp format_memory(bytes) when bytes < 1_048_576 do
    kb = Float.round(bytes / 1024, 1)
    "#{kb} KB"
  end

  defp format_memory(bytes) do
    mb = Float.round(bytes / 1_048_576, 1)
    "#{mb} MB"
  end

  defp relative_time(nil), do: "—"

  defp relative_time(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt)

    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      true -> "#{div(diff, 3600)}h ago"
    end
  end

  defp serialize_tree(nil), do: nil

  defp serialize_tree(tree) do
    Map.new(tree, fn {app, node} ->
      {to_string(app), serialize_node(node)}
    end)
  end

  defp serialize_node(node) do
    %{
      pid: pid_string(node.pid),
      name: node_name_to_string(node.name),
      type: node.type,
      has_children: node.has_children?,
      info: serialize_info(node.info),
      children: serialize_children(node.children)
    }
  end

  defp serialize_children(:not_loaded), do: nil

  defp serialize_children(children) when is_list(children),
    do: Enum.map(children, &serialize_node/1)

  defp serialize_info(nil), do: nil
  defp serialize_info(:dead), do: "dead"
  defp serialize_info(info) when is_map(info), do: Map.new(info, fn {k, v} -> {k, inspect(v)} end)

  defp serialize_errors(errors), do: Enum.map(errors, &inspect/1)
end
