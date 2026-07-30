defmodule VoyagerWeb.Components.SupervisionTreeComponents do
  @moduledoc """
  Components for the supervision tree.
  """

  use VoyagerWeb, :component

  @interval_options [
    {"Off", "off"},
    {"5s", "5000"},
    {"10s", "10000"},
    {"30s", "30000"},
    {"60s", "60000"}
  ]

  @erts "https://www.erlang.org/doc/apps/erts/erlang.html"
  @supervisor "https://www.erlang.org/doc/apps/stdlib/supervisor.html"

  @node_legends [
    %{
      name: "App",
      icon_name: "icon-diamond",
      text:
        "An OTP application: a component with its own supervision tree. This node wraps the application master and roots the tree for that app.",
      color_class: "text-primary",
      doc_href: "https://www.erlang.org/doc/system/applications.html",
      doc_label: "Learn about OTP applications"
    },
    %{
      name: "Supervisor",
      icon_name: "icon-square",
      text:
        "A process that starts, monitors, and restarts its children according to a restart strategy. Supervisors form the branches of the supervision tree.",
      color_class: "text-primary",
      doc_href: @supervisor,
      doc_label: "See the supervisor behaviour"
    },
    %{
      name: "Worker",
      icon_name: "icon-circle",
      text:
        "A non-supervisor child (e.g. a GenServer) that does the actual work. Workers are the leaves of the supervision tree.",
      color_class: "text-secondary",
      doc_href: @supervisor <> "#worker",
      doc_label: "See supervisor worker children"
    },
    %{
      name: "Port",
      icon_name: "icon-triangle",
      text:
        "An Erlang port: the VM's interface to the outside world (files, sockets, external programs). Discovered here through the processes that link to or monitor it.",
      color_class: "text-port",
      doc_href: "https://www.erlang.org/doc/system/ports.html",
      doc_label: "Learn about ports"
    },
    %{
      name: "Reference",
      icon_name: "icon-square",
      text:
        "An Erlang reference: a unique, opaque term rather than a live process. It appears here as the endpoint of a link or monitor relationship.",
      color_class: "text-success",
      doc_href: "https://www.erlang.org/doc/system/data_types.html#reference",
      doc_label: "Learn about references"
    }
  ]

  @edge_legends [
    %{
      name: "Supervision link",
      text:
        "A structural parent-child edge in the supervision tree: the supervisor directly starts and supervises this child.",
      color_class: "bg-base-500",
      doc_href: @supervisor,
      doc_label: "See the supervisor behaviour",
      dashed: false
    },
    %{
      name: "Link",
      text:
        "A bidirectional link between two processes. If either side crashes, the exit signal propagates to the other. Reported from both ends, so it is undirected.",
      color_class: "bg-base-400",
      doc_href: @erts <> "#link/1",
      doc_label: "See erlang:link/1",
      dashed: true
    },
    %{
      name: "Monitor",
      text:
        "A directed monitor: this process watches the target and receives a DOWN message if it terminates. Unlike a link, it is one-way and does not propagate exits.",
      color_class: "bg-process-monitor",
      doc_href: @erts <> "#monitor/2",
      doc_label: "See erlang:monitor/2",
      dashed: true
    },
    %{
      name: "Monitored by",
      text:
        "The reverse of a monitor: another process is watching this one and will be notified with a DOWN message when it terminates.",
      color_class: "bg-process-monitored-by",
      doc_href: @erts <> "#process_info/2",
      doc_label: "See erlang:process_info(monitored_by)",
      dashed: true
    }
  ]

  attr :node_name, :string, required: true
  attr :status, :atom, required: true
  attr :last_updated, :any, required: true
  attr :refresh_interval, :integer, default: nil

  def header(assigns) do
    ~H"""
    <div class="mx-auto w-full">
      <.node_header
        node_name={@node_name}
        last_updated={@last_updated}
        waiting_message="waiting for first fetch…"
      >
        <:actions>
          <span id="supervision-tree-status" class={["badge mr-2", status_badge_class(@status)]}>
            {status_label(@status)}
          </span>
          <.interval_select
            id="refresh-interval"
            options={interval_options()}
            refresh_interval={@refresh_interval}
            loading={@status == :loading}
          />
        </:actions>
      </.node_header>
    </div>
    """
  end

  attr :errors, :list, required: true

  def errors(assigns) do
    ~H"""
    <%= if @errors != [] do %>
      <div id="supervision-tree-errors" class="alert alert-error">
        <.icon name="icon-circle-alert" class="size-5 shrink-0" />
        <div class="w-full">
          <p class="font-semibold">Errors encountered</p>
          <ul class="max-h-[10vh] mt-1 w-full list-inside list-disc overflow-auto text-sm">
            <%= for err <- @errors do %>
              <li>{inspect(err)}</li>
            <% end %>
          </ul>
        </div>
        <div class="h-full">
          <button
            type="button"
            phx-click="dismiss_errors"
            title="Dismiss errors"
            aria-label="Dismiss errors"
            class="cursor-pointer rounded p-1 hover:bg-black/10"
          >
            <.icon name="icon-x" class="size-5" />
          </button>
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
            <.portal id="supervision-tree-node-snippet-portal" target="#tooltip-portal-root">
              <div
                id="supervision-tree-node-snippet-tip"
                role="tooltip"
                class={[
                  "tooltip-pop bg-base-100 text-base-content rounded-box max-w-lg px-3 py-2",
                  "ring-base-content/15 text-sm leading-relaxed shadow-lg ring-1"
                ]}
              >
              </div>
            </.portal>
            <div
              data-cy-container
              class="absolute inset-0 h-full cursor-grab active:cursor-grabbing"
            >
            </div>
            <div data-cy-overlays class="pointer-events-none absolute inset-0"></div>
            <div class="pointer-events-none absolute right-2 bottom-2 left-2 flex items-end justify-between">
              <div class="card bg-base-100 border-base-300 pointer-events-auto border">
                <div class="card-body font-mono text-base-content/80 flex-row flex-wrap gap-4 px-4 py-3 text-xs">
                  <.legend_node_entry
                    :for={entry <- node_legends()}
                    id={legend_entry_id(entry)}
                    {entry}
                  />
                  <.legend_edge_entry
                    :for={entry <- edge_legends()}
                    id={legend_entry_id(entry)}
                    {entry}
                  />
                </div>
              </div>
              <div class="card bg-base-100 border-base-300 pointer-events-auto m-2 border shadow-md">
                <div class="card-body p-1">
                  <button
                    type="button"
                    phx-click={JS.dispatch("zoom-in", to: "#supervision-tree-body")}
                    title="Zoom graph in"
                    aria-label="Zoom graph in"
                    class="btn btn-ghost btn-square toolbar-btn"
                  >
                    <.icon name="icon-plus" class="toolbar-icon" />
                  </button>
                  <button
                    type="button"
                    phx-click={JS.dispatch("zoom-out", to: "#supervision-tree-body")}
                    title="Zoom graph out"
                    aria-label="Zoom graph out"
                    class="btn btn-ghost btn-square toolbar-btn"
                  >
                    <.icon name="icon-minus" class="toolbar-icon" />
                  </button>
                  <button
                    type="button"
                    phx-click={JS.dispatch("maximize", to: "#supervision-tree-body")}
                    title="Fit graph to view"
                    aria-label="Fit graph to view"
                    class="btn btn-ghost btn-square toolbar-btn"
                  >
                    <.icon name="icon-maximize" class="toolbar-icon" />
                  </button>
                </div>
              </div>
            </div>
          </div>
      <% end %>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :icon_name, :string, required: true
  attr :name, :string, required: true
  attr :color_class, :string, required: true
  attr :text, :string, default: nil
  attr :doc_href, :string, default: nil
  attr :doc_label, :string, default: "Learn more"

  defp legend_node_entry(assigns) do
    ~H"""
    <.link_tooltip id={@id} doc_href={@doc_href} doc_label={@doc_label} interactive={true}>
      <span
        tabindex="0"
        aria-describedby={"#{@id}-tip"}
      >
        <.icon name={@icon_name} class={"#{@color_class} size-4"} /> {@name}
      </span>
      <:content>
        {@text}
      </:content>
    </.link_tooltip>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :color_class, :string, required: true
  attr :dashed, :boolean, default: true
  attr :text, :string, default: nil
  attr :doc_href, :string, default: nil
  attr :doc_label, :string, default: "Learn more"

  defp legend_edge_entry(assigns) do
    ~H"""
    <.link_tooltip id={@id} doc_href={@doc_href} doc_label={@doc_label} interactive={true}>
      <span
        tabindex="0"
        aria-describedby={"#{@id}-tip"}
        class="inline-flex items-center gap-1.5"
      >
        <span :for={_ <- 1..3} :if={@dashed} class={"#{@color_class} h-0.5 w-1.5"} />
        <span :if={not @dashed} class={"#{@color_class} w-7.5 h-0.5"} />
        <span class="ml-1">{@name}</span>
      </span>
      <:content>
        {@text}
      </:content>
    </.link_tooltip>
    """
  end

  defp interval_options, do: @interval_options

  def default_refresh_interval,
    do:
      interval_options()
      |> Enum.at(1)
      |> elem(1)
      |> String.to_integer()

  defp node_legends, do: @node_legends
  defp edge_legends, do: @edge_legends

  defp legend_entry_id(%{name: name}) do
    "#{name |> String.downcase() |> String.replace(" ", "-")}-legend-entry"
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
