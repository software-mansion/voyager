defmodule VoyagerWeb.NodeInfoLive do
  use VoyagerWeb, :live_view

  alias Voyager.NodeSession

  @refresh_interval 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(@refresh_interval, self(), :refresh_stats)
    end

    {:ok,
     socket
     |> assign(:active_nav, :node_info)
     |> assign(:stats, load_stats())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-4xl p-8">
      <.node_header session={@session} />
      <.main_stats stats={@stats} />

      <.info_section title="Memory">
        <.info_card label="Processes" value={format_bytes(memory_value(@stats, :processes))} />
        <.info_card label="Binary" value={format_bytes(memory_value(@stats, :binary))} />
        <.info_card label="ETS" value={format_bytes(memory_value(@stats, :ets))} />
        <.info_card label="Atom" value={format_bytes(memory_value(@stats, :atom))} />
      </.info_section>

      <%= if @session.info[:elixir_version] || @session.info[:phoenix_version] do %>
        <.info_section title="Versions">
          <%= if v = @session.info[:elixir_version] do %>
            <.info_card label="Elixir" value={to_string(v)} />
          <% end %>
          <%= if v = @session.info[:phoenix_version] do %>
            <.info_card label="Phoenix" value={to_string(v)} />
          <% end %>
          <%= if v = @session.info[:ecto_version] do %>
            <.info_card label="Ecto" value={to_string(v)} />
          <% end %>
          <%= if v = @session.info[:mix_version] do %>
            <.info_card label="Mix" value={to_string(v)} />
          <% end %>
        </.info_section>
      <% end %>
    </div>
    """
  end

  @impl true
  def handle_info(:refresh_stats, socket) do
    {:noreply, assign(socket, :stats, load_stats())}
  end

  attr :session, :map, required: true

  defp node_header(assigns) do
    ~H"""
    <div class="mb-8 flex flex-col gap-2">
      <h1 class="font-mono text-base-content flex items-center gap-3 text-2xl font-bold tracking-tight">
        {@session.node_name}
        <div class="badge badge-primary badge-outline badge-sm uppercase tracking-wider">
          {language_name(@session.language)}
        </div>
      </h1>
      <div class="flex flex-wrap items-center gap-2">
        <%= if otp = @session.info[:otp_release] do %>
          <div class="badge badge-ghost font-mono text-xs">OTP {to_string(otp)}</div>
        <% end %>
        <div class="badge badge-ghost font-mono text-xs">
          Connected {format_datetime(@session.connected_at)}
        </div>
      </div>
    </div>
    """
  end

  attr :stats, :map, required: true

  defp main_stats(assigns) do
    ~H"""
    <div class="stats stats-vertical bg-base-200 border-base-300 mb-8 w-full border shadow-sm sm:stats-horizontal">
      <div class="stat">
        <div class="stat-title font-mono text-[10.5px] uppercase tracking-wider">Processes</div>
        <div class="stat-value text-primary tabular-nums">{format_count(@stats[:process_count])}</div>
      </div>
      <div class="stat">
        <div class="stat-title font-mono text-[10.5px] uppercase tracking-wider">Run Queue</div>
        <div class="stat-value text-secondary tabular-nums">{format_count(@stats[:run_queue])}</div>
      </div>
      <div class="stat">
        <div class="stat-title font-mono text-[10.5px] uppercase tracking-wider">Total Memory</div>
        <div class="stat-value text-accent tabular-nums">
          {format_bytes(memory_value(@stats, :total))}
        </div>
      </div>
    </div>
    """
  end

  attr :title, :string, required: true
  slot :inner_block, required: true

  defp info_section(assigns) do
    ~H"""
    <section class="mb-8">
      <h2 class="font-mono text-[11px] tracking-[0.15em] text-base-content/50 mb-3 ml-1 font-semibold uppercase">
        {@title}
      </h2>
      <div class="grid grid-cols-2 gap-4 sm:grid-cols-4">
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp info_card(assigns) do
    ~H"""
    <div class="card bg-base-200 border-base-300 border shadow-sm">
      <div class="card-body justify-center gap-1 p-4">
        <div class="font-mono text-[10px] text-base-content/50 uppercase tracking-wider">
          {@label}
        </div>
        <div class="font-mono text-base-content truncate text-sm font-semibold" title={@value}>
          {@value}
        </div>
      </div>
    </div>
    """
  end

  defp load_stats do
    case NodeSession.fetch_stats() do
      {:ok, stats} -> stats
      _ -> %{}
    end
  end

  defp language_name(nil), do: "Detecting…"
  defp language_name(lang), do: lang.name()

  defp memory_value(stats, key) do
    case stats[:memory] do
      nil -> nil
      mem -> Keyword.get(mem, key)
    end
  end

  defp format_count(nil), do: "—"

  defp format_count(n) do
    n
    |> Integer.to_charlist()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.intersperse(~c",")
    |> List.flatten()
    |> Enum.reverse()
    |> List.to_string()
  end

  defp format_bytes(nil), do: "—"
  defp format_bytes(n) when n < 1_024, do: "#{n} B"
  defp format_bytes(n) when n < 1_048_576, do: "#{Float.round(n / 1_024, 1)} KB"
  defp format_bytes(n) when n < 1_073_741_824, do: "#{Float.round(n / 1_048_576, 1)} MB"
  defp format_bytes(n), do: "#{Float.round(n / 1_073_741_824, 2)} GB"

  defp format_datetime(dt), do: Calendar.strftime(dt, "%b %d, %H:%M")
end
