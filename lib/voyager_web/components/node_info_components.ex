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
