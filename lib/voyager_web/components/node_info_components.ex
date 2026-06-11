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

  @help_text %{
    "Uptime" =>
      "Lorem Ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.",
    "IO input" =>
      "Lorem Ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.",
    "IO output" =>
      "Lorem Ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.",
    "Reductions" =>
      "Lorem Ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.",
    "Runtime" =>
      "Lorem Ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.",
    "Schedulers" =>
      "Lorem Ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.",
    "Run queues" =>
      "Lorem Ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.",
    "Memory breakdown" =>
      "Lorem Ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.",
    "System limits" =>
      "Lorem Ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua."
  }

  defp help_text(label), do: Map.get(@help_text, label, "")

  # Documentation links shown as a "learn more" affordance inside each tooltip.
  # NOTE: verify these anchors against the OTP version you target — Erlang doc
  # URLs have changed across releases.
  @help_doc %{
    "Uptime" => "https://www.erlang.org/doc/man/erlang.html",
    "IO input" => "https://www.erlang.org/doc/man/erlang.html",
    "IO output" => "https://www.erlang.org/doc/man/erlang.html",
    "Reductions" => "https://www.erlang.org/doc/man/erlang.html",
    "Runtime" => "https://www.erlang.org/doc/man/erlang.html",
    "Schedulers" => "https://www.erlang.org/doc/man/erlang.html",
    "Run queues" => "https://www.erlang.org/doc/man/erlang.html",
    "Memory breakdown" => "https://www.erlang.org/doc/man/erlang.html",
    "System limits" => "https://www.erlang.org/doc/man/erlang.html"
  }

  defp help_doc(label), do: Map.get(@help_doc, label)

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
          <div class="flex items-center gap-1">
            <h3 class="text-base-content text-sm font-semibold">{@title}</h3>
            <.help_tooltip
              id={help_id("info-card", @title)}
              text={help_text(@title)}
              doc_href={help_doc(@title)}
            />
          </div>
          <span :if={@subtitle} class="font-mono text-base-content/50 text-xs">{@subtitle}</span>
        </div>

        <div class="grid grid-cols-2 gap-x-6 gap-y-3">
          <%= for row <- @rows do %>
            <% {label, value, full_width?} = info_row(row) %>
            <div class={full_width? && "col-span-2 min-w-0"}>
              <div class="font-mono tracking-[0.08em] text-base-content/50 mb-0.5 text-xs font-semibold uppercase">
                {label}
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

  def metric_card(assigns) do
    ~H"""
    <div class="card bg-base-100 border-base-200 flex min-h-0 flex-1 flex-col border shadow-sm">
      <div class="card-body flex flex-1 flex-col gap-4 p-5">
        <div class="flex items-baseline justify-between">
          <div class="flex items-center gap-1">
            <h3 class="text-base-content text-sm font-semibold">{@title}</h3>
            <.help_tooltip
              id={help_id("metric", @title)}
              text={help_text(@title)}
              doc_href={help_doc(@title)}
            />
          </div>
          <span :if={@subtitle} class="font-mono text-base-content/50 text-xs">{@subtitle}</span>
        </div>

        <div class="grid flex-1 auto-cols-fr grid-flow-col gap-3">
          <%= for {label, value} <- @metrics do %>
            <div class="bg-base-200/60 border-base-200 flex flex-1 flex-col items-center justify-center gap-1 rounded-lg border px-2 py-3">
              <span class="font-mono text-base-content text-xl font-medium leading-none tracking-tight">
                {value}
              </span>
              <span class="font-mono tracking-[0.08em] text-base-content/50 text-xs font-semibold uppercase">
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
      <div class="flex items-center gap-1">
        <h3 class="text-base-content text-sm font-semibold">{@label}</h3>
        <.help_tooltip
          id={help_id("stat", @label)}
          text={help_text(@label)}
          doc_href={help_doc(@label)}
        />
      </div>
      <div class="mt-1">
        <span class="font-mono text-base-content text-2xl font-medium leading-none tracking-tight">
          {@value}
        </span>
      </div>
      <div :if={@sub != []} class="font-mono text-base-content/50 text-xs">
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
          <div class="flex items-center gap-1">
            <h3 class="text-base-content text-sm font-semibold">Memory breakdown</h3>
            <.help_tooltip
              id="memory-breakdown-help"
              text={help_text("Memory breakdown")}
              doc_href={help_doc("Memory breakdown")}
            />
          </div>
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
            <div class="font-mono flex items-center gap-2.5 text-xs">
              <div class={["size-2.5 shrink-0 rounded-sm", color_class]}></div>
              <span class="text-base-content/70 min-w-0 flex-1">{label}</span>
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
    <div class="card bg-base-100 border-base-200 flex h-full flex-col border shadow-sm">
      <div class="card-body flex flex-1 flex-col gap-4 p-5">
        <div class="flex items-baseline justify-between">
          <div class="flex items-center gap-1">
            <h3 class="text-base-content text-sm font-semibold">System limits</h3>
            <.help_tooltip
              id="system-limits-help"
              text={help_text("System limits")}
              doc_href={help_doc("System limits")}
            />
          </div>
          <span class="font-mono text-base-content/50 text-xs">current / max</span>
        </div>

        <div class="divide-base-200 flex flex-1 flex-col divide-y">
          <%= for {label, usage} <- limit_rows(@limits) do %>
            <div class="font-mono grid-cols-[1fr_auto_1fr_auto] grid items-center gap-3 py-3 text-xs">
              <span class="text-base-content/70">{label}</span>
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
              <span class="text-base-content/40 w-16 tabular-nums">
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
      {"ports", limits.ports}
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
