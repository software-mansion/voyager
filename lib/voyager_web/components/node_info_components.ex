defmodule VoyagerWeb.NodeInfoComponents do
  @moduledoc """
  Components for the node info page.
  """

  use VoyagerWeb, :component

  alias Voyager.Services.NodeInfo.Limits
  alias Voyager.Services.NodeInfo.Memory
  alias VoyagerWeb.Formatters
  alias VoyagerWeb.NodeInfoHelp
  alias VoyagerWeb.Utils.URL

  @memory_segments [
    {:processes_allocated, "Processes", "bg-primary"},
    {:binary, "Binary", "bg-primary/75"},
    {:code, "Code", "bg-primary/55"},
    {:ets, "ETS", "bg-primary/38"},
    {:atom_allocated, "Atom", "bg-primary/22"},
    {:other, "Other", "bg-base-300"}
  ]

  @doc """
  Renders a key-value info card with a 2-column grid of labelled rows.

  Each row is `{label, value}` or `{label, value, opts}`, where `opts` is a
  keyword list supporting `:full` (span both columns) and `:help` (a help entry
  from `NodeInfoHelp` rendered as a per-row tooltip).

  ## Examples

      <NodeInfoComponents.info_card
        title="Runtime"
        subtitle="ERTS · system info"
        rows={[
          {"OTP", "27.1", help: NodeInfoHelp.get(:otp)},
          {"System arch", "x86_64-...", full: true}
        ]}
      />
  """
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :rows, :list, required: true
  attr :help, :map, default: nil, doc: "optional help entry for the card title (see NodeInfoHelp)"

  def info_card(assigns) do
    ~H"""
    <div class="card bg-base-100 border-base-200 h-full border shadow-sm">
      <div class="card-body gap-4 p-5">
        <div class="flex items-baseline justify-between">
          <div class="min-h-6 flex items-center gap-1">
            <h3 class="text-base-content text-sm font-semibold">{@title}</h3>
            <.help_tooltip
              :if={@help}
              id={help_id("info-card", @title)}
              text={@help.text}
              doc_href={@help[:doc_href]}
              doc_label={@help[:doc_label] || "Learn more"}
            />
          </div>
          <span :if={@subtitle} class="font-mono text-base-content/70 text-xs">{@subtitle}</span>
        </div>

        <div class="grid grid-cols-2 gap-x-6 gap-y-3">
          <%= for row <- @rows do %>
            <% {label, value, full_width?, help} = info_row(row) %>
            <div class={full_width? && "col-span-2 min-w-0"}>
              <div class="font-mono tracking-label text-base-content/70 mb-0.5 flex items-center gap-0.5 text-xs font-semibold uppercase">
                {label}
                <.help_tooltip
                  :if={help}
                  id={help_id("row", label)}
                  text={help.text}
                  doc_href={help[:doc_href]}
                  doc_label={help[:doc_label] || "Learn more"}
                />
              </div>
              <div class={["font-mono text-base-content text-sm", full_width? && "truncate"]}>
                {value}
              </div>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a metric card: a titled card showing a row of labelled metric columns.

  ## Examples

      <NodeInfoComponents.metric_card
        title="Schedulers"
        metrics={[{"Online", "8"}, {"Total", "8"}, {"Available", "8"}]}
      />
  """
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :metrics, :list, required: true
  attr :help, :map, default: nil, doc: "optional help entry for the card title (see NodeInfoHelp)"

  def metric_card(assigns) do
    ~H"""
    <div class="card bg-base-100 border-base-200 flex min-h-0 flex-1 flex-col border shadow-sm">
      <div class="card-body flex flex-1 flex-col gap-4 p-5">
        <div class="flex items-baseline justify-between">
          <div class="min-h-6 flex items-center gap-1">
            <h3 class="text-base-content text-sm font-semibold">{@title}</h3>
            <.help_tooltip
              :if={@help}
              id={help_id("metric", @title)}
              text={@help.text}
              doc_href={@help[:doc_href]}
              doc_label={@help[:doc_label] || "Learn more"}
            />
          </div>
          <span :if={@subtitle} class="font-mono text-base-content/70 text-xs">{@subtitle}</span>
        </div>

        <div class="grid flex-1 auto-cols-fr grid-flow-col gap-3">
          <%= for {label, value} <- @metrics do %>
            <div class="bg-base-200 border-base-300 flex flex-1 flex-col items-center justify-center gap-1 rounded-lg border px-2 py-3">
              <span class="font-mono text-base-content text-xl font-medium leading-none tracking-tight">
                {value}
              </span>
              <span class="font-mono tracking-label text-base-content/70 text-xs font-semibold uppercase">
                {label}
              </span>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a compact stat tile with a label, large value, and optional sub-line.

  ## Examples

      <.stat_tile label="Uptime" value="4d 1h">
        <:sub>since 24 Apr 2026</:sub>
      </.stat_tile>
  """
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :help, :map, default: nil, doc: "optional help entry for the tile (see NodeInfoHelp)"

  slot :sub

  def stat_tile(assigns) do
    ~H"""
    <div class="card bg-base-100 border-base-200 flex flex-col gap-1.5 border p-5 shadow-sm">
      <div class="min-h-6 flex items-center gap-1">
        <h3 class="text-base-content text-sm font-semibold">{@label}</h3>
        <.help_tooltip
          :if={@help}
          id={help_id("stat", @label)}
          text={@help.text}
          doc_href={@help[:doc_href]}
          doc_label={@help[:doc_label] || "Learn more"}
        />
      </div>
      <div class="mt-1">
        <span class="font-mono text-base-content text-2xl font-medium leading-none tracking-tight">
          {@value}
        </span>
      </div>
      <div :if={@sub != []} class="font-mono text-base-content/70 text-xs">
        {render_slot(@sub)}
      </div>
    </div>
    """
  end

  @doc """
  Renders a memory breakdown card with a stacked bar chart and legend.
  """
  attr :memory, Memory, required: true
  attr :help, :map, default: nil, doc: "optional help entry for the card title (see NodeInfoHelp)"

  def memory_card(assigns) do
    assigns = assign(assigns, :segments, memory_segments(assigns.memory))

    ~H"""
    <div class="card bg-base-100 border-base-200 border shadow-sm">
      <div class="card-body gap-4 p-5">
        <div class="flex items-baseline justify-between">
          <div class="min-h-6 flex items-center gap-1">
            <h3 class="text-base-content text-sm font-semibold">Memory breakdown</h3>
            <.help_tooltip
              :if={@help}
              id="memory-breakdown-help"
              text={@help.text}
              doc_href={@help[:doc_href]}
              doc_label={@help[:doc_label] || "Learn more"}
            />
          </div>
          <span class="font-mono text-base-content/70 text-xs">
            {Formatters.format_bytes(@memory.total)} total
          </span>
        </div>

        <%!-- Stacked bar --%>
        <div class="flex h-5 w-full overflow-hidden rounded">
          <%= for {_key, label, color_class, pct} <- @segments do %>
            <div
              class={["transition-opacity hover:opacity-75", color_class]}
              style={"width: #{pct}%"}
              title={"#{label}: #{pct}%"}
            >
            </div>
          <% end %>
        </div>

        <%!-- Legend rows --%>
        <div class="flex flex-col gap-2">
          <%= for {key, label, color_class, pct} <- @segments do %>
            <div class="font-mono flex items-center gap-2.5 text-xs">
              <div class={["size-2.5 shrink-0 rounded-sm", color_class]}></div>
              <span class="text-base-content/80 min-w-0 flex-1">{label}</span>
              <span class="text-base-content tabular-nums">
                {Formatters.format_bytes(Map.get(@memory, key))}
              </span>
              <span class="text-base-content/70 w-12 text-right tabular-nums">
                {pct}%
              </span>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a system limits card with a meter bar for each resource.
  """
  attr :limits, Limits, required: true

  def limits_card(assigns) do
    ~H"""
    <div class="card bg-base-100 border-base-200 flex h-full flex-col border shadow-sm">
      <div class="card-body flex flex-1 flex-col gap-4 p-5">
        <div class="flex items-baseline justify-between">
          <h3 class="text-base-content min-h-6 flex items-center text-sm font-semibold">
            System limits
          </h3>
          <span class="font-mono text-base-content/70 text-xs">current / max</span>
        </div>

        <div class="divide-base-content/10 flex flex-1 flex-col divide-y">
          <%= for {label, usage, tooltip} <- limit_rows(@limits) do %>
            <div class="font-mono grid-cols-limits grid items-center gap-3 py-3 text-xs">
              <span class="text-base-content/80 flex items-center gap-0.5">
                {label}
                <.help_tooltip
                  id={"limit-#{label}-help"}
                  text={tooltip.text}
                  doc_href={tooltip[:doc_href]}
                  doc_label={tooltip[:doc_label] || "Learn more"}
                />
              </span>
              <span class="text-base-content w-16 text-right tabular-nums">
                {Formatters.format_integer(usage.used)}
              </span>
              <div class="bg-base-200 h-2 overflow-hidden rounded-full">
                <div
                  class={["h-full rounded-full transition-all", meter_color(usage)]}
                  style={"width: #{meter_pct(usage)}%"}
                >
                </div>
              </div>
              <span class="text-base-content/70 w-16 tabular-nums">
                {Formatters.format_integer(usage.limit)}
              </span>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a running-applications table, capped to `visible_count` rows with a
  "Show all" affordance for the remainder. `load_more_event` is the
  `phx-click` event name the parent LiveView handles.

  ## Examples

      <NodeInfoComponents.applications_card
        applications={snapshot.applications}
        visible_count={@visible_app_count}
        load_more_event="load-more-apps"
      />
  """
  attr :applications, :list, required: true
  attr :visible_count, :integer, required: true
  attr :load_more_event, :string, required: true
  attr :node_name, :string, required: true, doc: "used to link a row to its supervision tree"
  attr :current_url, :string, default: nil
  attr :help, :map, default: nil, doc: "optional help entry for the card title (see NodeInfoHelp)"

  def applications_card(assigns) do
    total = length(assigns.applications)

    assigns =
      assign(assigns,
        visible_applications: Enum.take(assigns.applications, assigns.visible_count),
        total: total,
        remaining: max(total - assigns.visible_count, 0)
      )

    ~H"""
    <div class="card bg-base-100 border-base-200 border shadow-sm">
      <div class="card-body gap-4 p-5">
        <div class="mb-2 flex items-baseline justify-between">
          <div class="min-h-6 flex items-center gap-1">
            <h3 class="text-base-content text-sm font-semibold">Running applications</h3>
            <.help_tooltip
              :if={@help}
              id="applications-help"
              text={@help.text}
              doc_href={@help[:doc_href]}
              doc_label={@help[:doc_label] || "Learn more"}
            />
          </div>
          <span class="font-mono text-base-content/70 text-xs">{@total} running</span>
        </div>

        <div class="overflow-x-auto">
          <table class="w-full table-fixed text-left">
            <thead>
              <tr class="border-base-content/10 border-b">
                <th class="font-mono tracking-label text-base-content/70 w-1/4 px-2 pb-2 text-xs font-semibold uppercase">
                  Application
                </th>
                <th class="font-mono tracking-label text-base-content/70 w-28 px-2 pb-2 text-xs font-semibold uppercase">
                  Version
                </th>
                <th class="font-mono tracking-label text-base-content/70 px-2 pb-2 text-xs font-semibold uppercase">
                  Description
                </th>
                <th class="font-mono tracking-label text-base-content/70 w-10 px-2 pb-2 text-right text-xs font-semibold uppercase">
                  <span class="sr-only">Actions</span>
                </th>
              </tr>
            </thead>
            <tbody class="divide-base-content/10 divide-y">
              <tr :for={app <- @visible_applications}>
                <td class="text-base-content truncate px-2 py-2.5 text-sm font-medium">
                  {app.name}
                </td>
                <td class="px-2 py-2.5">
                  <span class="bg-base-200/80 border-base-200 text-base-content/80 font-mono rounded border px-1.5 py-0.5 text-xs">
                    {app.version}
                  </span>
                </td>
                <td
                  class="text-base-content/70 px-2 py-2.5 text-sm"
                  title={app.description}
                >
                  {app.description}
                </td>
                <td class="px-2 py-2.5 text-right">
                  <.tooltip
                    :if={app.has_supervision_tree}
                    id={"app-tree-#{app.name}"}
                    position="left"
                  >
                    <.link
                      navigate={application_href(@node_name, app.name, @current_url)}
                      aria-label={"View #{app.name} supervision tree"}
                      class="btn btn-ghost btn-square toolbar-btn-sm text-base-content/70 hover:text-primary"
                    >
                      <.icon name="icon-network" class="toolbar-icon-sm" />
                    </.link>
                    <:content>View supervision tree</:content>
                  </.tooltip>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div :if={@remaining > 0} class="flex justify-center">
          <button
            type="button"
            id="applications-show-all-button"
            class="btn btn-ghost btn-sm"
            phx-click={@load_more_event}
          >
            Show all
          </button>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a DaisyUI modal for displaying pre-encoded JSON with a copy action.

  ## Examples

      <NodeInfoComponents.json_snapshot_modal
        id="node-info-json-modal"
        show={@show_json_modal?}
        title="Node snapshot JSON"
        description="Point-in-time data from the latest successful node inspection."
        json={@snapshot_json}
        on_close="close-json-modal"
      />
  """
  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :json, :string, default: nil
  attr :on_close, :any, required: true
  attr :copy_label, :string, default: "Copy JSON"

  def json_snapshot_modal(assigns) do
    content_id = "#{assigns.id}-content"

    assigns =
      assigns
      |> assign(:title_id, "#{assigns.id}-title")
      |> assign(:content_id, content_id)
      |> assign(:close_id, "#{assigns.id}-close")
      |> assign(:copy_id, "#{assigns.id}-copy")
      |> assign(:backdrop_id, "#{assigns.id}-backdrop")
      |> assign(:copy_target, "##{content_id}")

    ~H"""
    <div
      :if={@show}
      id={@id}
      role="dialog"
      aria-modal="true"
      aria-labelledby={@title_id}
      phx-window-keydown={@on_close}
      phx-key="Escape"
      class="modal modal-open"
    >
      <div class="modal-box border-base-300 max-w-4xl overflow-hidden border p-0 shadow-2xl">
        <div class="border-base-300 flex items-start gap-4 border-b p-6">
          <div class="bg-primary/10 text-primary rounded-box size-11 flex shrink-0 items-center justify-center">
            <.icon name="icon-file-braces" class="size-5" />
          </div>
          <div class="min-w-0 flex-1">
            <h2 id={@title_id} class="text-base-content text-xl font-semibold tracking-tight">
              {@title}
            </h2>
            <p :if={@description} class="text-base-content/70 mt-1 text-sm">
              {@description}
            </p>
          </div>
          <button
            type="button"
            id={@close_id}
            phx-click={@on_close}
            title="Close JSON snapshot"
            aria-label="Close JSON snapshot"
            class="btn btn-ghost btn-square toolbar-btn text-base-content/60 hover:text-base-content"
          >
            <.icon name="icon-x" class="toolbar-icon" />
          </button>
        </div>

        <div class="p-6">
          <pre
            id={@content_id}
            phx-no-curly-interpolation
            class="bg-base-200 text-base-content rounded-box font-mono max-h-96 overflow-auto p-5 text-xs leading-relaxed"
          ><%= @json %></pre>
        </div>

        <div class="border-base-300 flex justify-end border-t p-4">
          <.copy_button id={@copy_id} target={@copy_target} label={@copy_label} />
        </div>
      </div>

      <button
        type="button"
        id={@backdrop_id}
        phx-click={@on_close}
        class="modal-backdrop"
        aria-label="Close JSON snapshot"
      >
        Close
      </button>
    </div>
    """
  end

  defp application_href(node_name, app_name, current_url) do
    path = "/node/#{URI.encode(node_name)}/supervision-tree"
    params = %{"apps" => to_string(app_name)}

    params =
      case current_url && URL.get_query_param(current_url, "sidebar") do
        mode when mode in ["compact", "full"] -> Map.put(params, "sidebar", mode)
        _ -> params
      end

    URL.put_query_params(path, params)
  end

  defp limit_rows(limits) do
    [
      {"processes", limits.processes, NodeInfoHelp.get(:processes)},
      {"atoms", limits.atoms, NodeInfoHelp.get(:atoms)},
      {"ports", limits.ports, NodeInfoHelp.get(:ports)}
    ]
  end

  defp meter_pct(%{used: used, limit: limit}) when limit > 0,
    do: Float.round(max(used / limit * 100, 0.5), 1)

  defp meter_pct(_), do: 0.5

  defp meter_color(%{used: used, limit: limit}) when limit > 0 do
    pct = used / limit * 100

    cond do
      pct >= 90 -> "bg-error"
      pct >= 70 -> "bg-warning"
      true -> "bg-primary"
    end
  end

  defp meter_color(_), do: "bg-primary"

  defp info_row({label, value}), do: {label, value, false, nil}

  defp info_row({label, value, opts}) when is_list(opts),
    do: {label, value, Keyword.get(opts, :full, false), Keyword.get(opts, :help)}

  defp help_id(prefix, label) do
    slug =
      label
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    "#{prefix}-#{slug}-help"
  end

  defp memory_segments(%Memory{total: total}) when total == 0 or is_nil(total), do: []

  defp memory_segments(memory) do
    Enum.map(@memory_segments, fn {key, label, color_class} ->
      value = Map.get(memory, key) || 0
      pct = Float.round(value / memory.total * 100, 1)
      {key, label, color_class, pct}
    end)
  end
end
