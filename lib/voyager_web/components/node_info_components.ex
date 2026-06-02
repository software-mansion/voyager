defmodule VoyagerWeb.NodeInfoComponents do
  @moduledoc """
  Components for the node info page.
  """

  use VoyagerWeb, :component

  alias Voyager.Services.NodeInfo.Limits
  alias Voyager.Services.NodeInfo.Memory
  alias VoyagerWeb.Formatters

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

  ## Examples

      <NodeInfoComponents.info_card
        title="Runtime"
        subtitle="ERTS · system info"
        rows={[
          {"OTP version", "27.1"},
          {"ERTS version", "15.1"}
        ]}
      />
  """
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :rows, :list, required: true

  def info_card(assigns) do
    ~H"""
    <div class="card bg-base-100 border-base-200 h-full border shadow-sm">
      <div class="card-body gap-4 p-5">
        <div class="flex items-baseline justify-between">
          <h3 class="text-base-content text-sm font-semibold">{@title}</h3>
          <span :if={@subtitle} class="font-mono text-base-content/50 text-xs">{@subtitle}</span>
        </div>

        <div class="grid grid-cols-2 gap-x-6 gap-y-3">
          <%= for row <- @rows do %>
            <% {label, value, full_width?} = info_row(row) %>
            <div class={full_width? && "col-span-2 min-w-0"}>
              <div class="font-mono text-[10px] tracking-[0.08em] text-base-content/50 mb-0.5 font-semibold uppercase">
                {label}
              </div>
              <div class={["font-mono text-[13px] text-base-content", full_width? && "truncate"]}>
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

  def metric_card(assigns) do
    ~H"""
    <div class="card bg-base-100 border-base-200 flex min-h-0 flex-1 flex-col border shadow-sm">
      <div class="card-body flex flex-1 flex-col gap-4 p-5">
        <div class="flex items-baseline justify-between">
          <h3 class="text-base-content text-sm font-semibold">{@title}</h3>
          <span :if={@subtitle} class="font-mono text-base-content/50 text-xs">{@subtitle}</span>
        </div>

        <div class="grid flex-1 auto-cols-fr grid-flow-col gap-3">
          <%= for {label, value} <- @metrics do %>
            <div class="bg-base-200/60 border-base-200 flex flex-1 flex-col items-center justify-center gap-1 rounded-lg border px-2 py-3">
              <span class="font-mono text-[22px] text-base-content font-medium leading-none tracking-tight">
                {value}
              </span>
              <span class="font-mono text-[9.5px] tracking-[0.08em] text-base-content/50 font-semibold uppercase">
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

  slot :sub

  def stat_tile(assigns) do
    ~H"""
    <div class="card bg-base-100 border-base-200 flex flex-col gap-1.5 border p-5 shadow-sm">
      <h3 class="text-base-content text-sm font-semibold">{@label}</h3>
      <div class="mt-1">
        <span class="font-mono text-[26px] text-base-content font-medium leading-none tracking-tight">
          {@value}
        </span>
      </div>
      <div :if={@sub != []} class="font-mono text-[11px] text-base-content/50">
        {render_slot(@sub)}
      </div>
    </div>
    """
  end

  @doc """
  Renders a memory breakdown card with a stacked bar chart and legend.
  """
  attr :memory, Memory, required: true

  def memory_card(assigns) do
    assigns = assign(assigns, :segments, memory_segments(assigns.memory))

    ~H"""
    <div class="card bg-base-100 border-base-200 border shadow-sm">
      <div class="card-body gap-4 p-5">
        <div class="flex items-baseline justify-between">
          <h3 class="text-base-content text-sm font-semibold">Memory breakdown</h3>
          <span class="font-mono text-base-content/50 text-xs">
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
            <div
              class="font-mono grid items-center gap-2.5 text-xs"
              style="grid-template-columns: 10px 1fr auto auto;"
            >
              <div class={["size-2.5 shrink-0 rounded-sm", color_class]}></div>
              <span class="text-base-content/70">{label}</span>
              <span class="text-base-content tabular-nums">
                {Formatters.format_bytes(Map.get(@memory, key))}
              </span>
              <span class="text-base-content/40 w-12 text-right tabular-nums">
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
    <div class="card bg-base-100 border-base-200 border shadow-sm">
      <div class="card-body gap-4 p-5">
        <div class="flex items-baseline justify-between">
          <h3 class="text-base-content text-sm font-semibold">System limits</h3>
          <span class="font-mono text-base-content/50 text-xs">current / max</span>
        </div>

        <div class="divide-base-200 flex flex-col divide-y">
          <%= for {label, usage} <- limit_rows(@limits) do %>
            <div
              class="font-mono grid items-center gap-3 py-2 text-xs first:pt-0 last:pb-0"
              style="grid-template-columns: 1fr 4rem 1fr 4rem;"
            >
              <span class="text-base-content/70">{label}</span>
              <span class="text-base-content text-right tabular-nums">
                {Formatters.format_integer(usage.used)}
              </span>
              <div class="bg-base-200 h-1 overflow-hidden rounded-full">
                <div
                  class={["h-full rounded-full transition-all", meter_color(usage)]}
                  style={"width: #{meter_pct(usage)}%"}
                >
                </div>
              </div>
              <span class="text-base-content/40 tabular-nums">
                {Formatters.format_integer(usage.limit)}
              </span>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp limit_rows(limits) do
    [
      {"processes", limits.processes},
      {"atoms", limits.atoms},
      {"ports", limits.ports},
      {"ets tables", limits.ets}
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

  defp info_row({label, value}), do: {label, value, false}
  defp info_row({label, value, :full}), do: {label, value, true}

  defp memory_segments(%Memory{total: total}) when total == 0 or is_nil(total), do: []

  defp memory_segments(memory) do
    Enum.map(@memory_segments, fn {key, label, color_class} ->
      value = Map.get(memory, key) || 0
      pct = Float.round(value / memory.total * 100, 1)
      {key, label, color_class, pct}
    end)
  end
end
