defmodule VoyagerWeb.NodeInfoComponents do
  @moduledoc """
  Components for the node info page.
  """

  use VoyagerWeb, :component

  alias Voyager.Services.NodeInfo.Limits
  alias Voyager.Services.NodeInfo.Memory

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

  ## Slots

  - `row` (required) — each entry; provide `label` and `value` attrs

  ## Examples

      <.info_card title="Runtime" subtitle="ERTS · system info">
        <:row label="OTP version" value="27.1" />
        <:row label="ERTS version" value="15.1" />
      </.info_card>
  """
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil

  slot :row, required: true do
    attr :label, :string, required: true
    attr :value, :string, required: true
  end

  def info_card(assigns) do
    ~H"""
    <div class="card bg-base-100 border border-base-200 shadow-sm">
      <div class="card-body gap-4 p-5">
        <div class="flex items-baseline justify-between">
          <h3 class="font-semibold text-base-content text-sm">{@title}</h3>
          <span :if={@subtitle} class="font-mono text-xs text-base-content/50">{@subtitle}</span>
        </div>

        <div class="grid grid-cols-2 gap-x-6 gap-y-3">
          <%= for entry <- @row do %>
            <div>
              <div class="font-mono text-[10px] font-semibold uppercase tracking-[0.08em] text-base-content/50 mb-0.5">
                {entry.label}
              </div>
              <div class="font-mono text-[13px] text-base-content">
                {entry.value}
              </div>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a compact stat tile with a label, large value, optional unit, and optional sub-line.

  ## Slots

  - `value` (required) — the primary numeric or text value; use the `unit` attr for a trailing unit label
  - `sub` (optional) — a small secondary line below the value (e.g. "limit 262,144")

  ## Examples

      <.stat_tile label="Processes">
        <:value unit="live">31</:value>
        <:sub>limit 262,144</:sub>
      </.stat_tile>
  """
  attr :label, :string, required: true

  slot :value, required: true do
    attr :unit, :string
  end

  slot :sub

  def stat_tile(assigns) do
    ~H"""
    <div class="card bg-base-100 border border-base-200 shadow-sm p-5 flex flex-col gap-1.5">
      <span class="font-mono text-[10.5px] font-semibold uppercase tracking-[0.1em] text-base-content/50">
        {@label}
      </span>
      <%= for entry <- @value do %>
        <div class="mt-1 flex items-baseline gap-1.5">
          <span class="font-mono text-[26px] font-medium leading-none tracking-tight text-base-content">
            {render_slot(entry)}
          </span>
          <span :if={Map.get(entry, :unit)} class="font-mono text-sm text-base-content/50">
            {entry.unit}
          </span>
        </div>
      <% end %>
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
    <div class="card bg-base-100 border border-base-200 shadow-sm">
      <div class="card-body gap-4 p-5">
        <div class="flex items-baseline justify-between">
          <h3 class="font-semibold text-base-content text-sm">Memory breakdown</h3>
          <span class="font-mono text-xs text-base-content/50">
            {format_bytes(@memory.total)} total
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
            <div class="grid items-center gap-2.5 font-mono text-xs" style="grid-template-columns: 10px 1fr auto auto;">
              <div class={["size-2.5 rounded-sm shrink-0", color_class]}></div>
              <span class="text-base-content/70">{label}</span>
              <span class="text-base-content tabular-nums">
                {format_bytes(Map.get(@memory, key))}
              </span>
              <span class="w-12 text-right text-base-content/40 tabular-nums">
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
    <div class="card bg-base-100 border border-base-200 shadow-sm">
      <div class="card-body gap-4 p-5">
        <div class="flex items-baseline justify-between">
          <h3 class="font-semibold text-base-content text-sm">System limits</h3>
          <span class="font-mono text-xs text-base-content/50">current / max</span>
        </div>

        <div class="flex flex-col divide-y divide-base-200">
          <%= for {label, usage} <- limit_rows(@limits) do %>
            <div class="grid items-center gap-3 py-2 font-mono text-xs first:pt-0 last:pb-0"
                 style="grid-template-columns: 1fr 4rem 1fr 4rem;">
              <span class="text-base-content/70">{label}</span>
              <span class="text-right text-base-content tabular-nums">{format_int(usage.used)}</span>
              <div class="bg-base-200 h-1 overflow-hidden rounded-full">
                <div
                  class={["h-full rounded-full transition-all", meter_color(usage)]}
                  style={"width: #{meter_pct(usage)}%"}
                >
                </div>
              </div>
              <span class="text-base-content/40 tabular-nums">{format_int(usage.limit)}</span>
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

  defp format_int(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp memory_segments(%Memory{total: total}) when total == 0 or is_nil(total), do: []

  defp memory_segments(memory) do
    Enum.map(@memory_segments, fn {key, label, color_class} ->
      value = Map.get(memory, key) || 0
      pct = Float.round(value / memory.total * 100, 1)
      {key, label, color_class, pct}
    end)
  end

  defp format_bytes(nil), do: "—"

  defp format_bytes(bytes) when bytes >= 1_073_741_824 do
    "#{Float.round(bytes / 1_073_741_824, 1)} GB"
  end

  defp format_bytes(bytes) when bytes >= 1_048_576 do
    "#{round(bytes / 1_048_576)} MB"
  end

  defp format_bytes(bytes) when bytes >= 1_024 do
    "#{round(bytes / 1_024)} KB"
  end

  defp format_bytes(bytes), do: "#{bytes} B"
end
