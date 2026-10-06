defmodule VoyagerWeb.TracingLive do
  use VoyagerWeb, :live_view

  alias Voyager.Services.Tracer

  @shown_events 200

  @examples [
    %{
      id: "gen-call",
      label: "GenServer calls",
      hint: "GenServer.call and :gen_server.call",
      spec: %{module: "gen", function: "call", arity: 4, capture: :args, local: false}
    },
    %{
      id: "erpc",
      label: "Incoming erpc",
      hint: "Requests from Voyager and other nodes",
      spec: %{module: "erpc", function: "execute_call", arity: 4, capture: :args, local: false}
    },
    %{
      id: "logger",
      label: "Log calls",
      hint: "Logger and :logger at any level",
      spec: %{module: "logger", function: "macro_log", arity: 4, capture: :args, local: false}
    },
    %{
      id: "ets-insert",
      label: "ETS inserts",
      hint: "Arity only: rows can be large",
      spec: %{module: "ets", function: "insert", arity: 2, capture: :arity, local: false}
    },
    %{
      id: "ets-lookup",
      label: "ETS lookups",
      hint: "Usually hot: trips the rate limit",
      spec: %{module: "ets", function: "lookup", arity: 2, capture: :arity, local: false}
    },
    %{
      id: "enum-map",
      label: "Enum.map/2",
      hint: "Elixir nodes only",
      spec: %{module: "Elixir.Enum", function: "map", arity: 2, capture: :arity, local: false}
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Voyager.PubSub, Tracer.topic())

    {trace, events} = Tracer.current()

    socket
    |> assign(:active_nav, :tracing)
    |> assign(:limits, Tracer.limits())
    |> assign(:trace, trace)
    |> assign(
      :form,
      to_form(%{"mfa" => "", "capture" => "arity", "local" => "false"}, as: :trace)
    )
    |> stream(:events, Enum.take(events, @shown_events))
    |> ok()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-screen-2xl space-y-6 p-6 sm:p-8">
      <header>
        <h1 class="text-base-content text-2xl font-bold tracking-tight">Tracing</h1>
        <p class="text-base-content/70 mt-1 text-sm">
          One trace at a time. It stops by itself after {@limits.max_events} events, over {@limits.max_rate} events/s, or after {div(
            @limits.max_time_ms,
            1000
          )} s.
        </p>
      </header>

      <section id="trace-start-card" class="card bg-base-100 border-base-200 border shadow-sm">
        <div class="card-body gap-5 p-5">
          <h2 class="text-base-content text-sm font-semibold">Examples</h2>
          <div class="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
            <button
              :for={example <- examples()}
              id={"trace-example-#{example.id}"}
              type="button"
              phx-click="start_example"
              phx-value-id={example.id}
              disabled={running?(@trace)}
              class="btn border-base-300 h-auto flex-col items-start gap-1 py-3 text-left font-normal transition-transform hover:-translate-y-0.5"
            >
              <span class="text-base-content font-semibold">{example.label}</span>
              <span class="font-mono text-base-content/70 text-xs">
                {Tracer.spec_label(example.spec)}
              </span>
              <span class="text-base-content/60 text-xs">{example.hint}</span>
            </button>
          </div>

          <.form
            for={@form}
            id="trace-form"
            phx-submit="start_custom"
            class="border-base-content/10 flex flex-wrap items-center gap-3 border-t pt-5"
          >
            <div class="min-w-64 flex-1">
              <.input
                field={@form[:mfa]}
                placeholder="Module.function/arity, e.g. Enum.map/2 or :ets.insert/2"
                autocomplete="off"
                spellcheck="false"
                class="font-mono"
              />
            </div>
            <select
              id="trace-capture"
              name={@form[:capture].name}
              class="select select-bordered w-auto"
            >
              <option value="arity" selected={@form[:capture].value == "arity"}>Arity only</option>
              <option value="args" selected={@form[:capture].value == "args"}>Arguments</option>
            </select>
            <label class="label text-base-content cursor-pointer gap-2 text-sm">
              <input type="hidden" name={@form[:local].name} value="false" />
              <input
                id="trace-local"
                type="checkbox"
                name={@form[:local].name}
                value="true"
                checked={@form[:local].value == "true"}
                class="checkbox checkbox-sm"
              /> Include local calls
            </label>
            <button id="trace-start" type="submit" class="btn btn-primary" disabled={running?(@trace)}>
              Start
            </button>
          </.form>
        </div>
      </section>

      <section
        :if={@trace}
        id="trace-status"
        class="card bg-base-100 border-base-200 border shadow-sm"
      >
        <div class="card-body flex-row flex-wrap items-center gap-4 p-5">
          <div class="flex min-w-0 flex-col gap-1.5">
            <div class="flex items-center gap-2">
              <span class={["badge", if(running?(@trace), do: "badge-success", else: "badge-ghost")]}>
                {Tracer.status_text(@trace)}
              </span>
              <span :if={@trace.origin == :mcp} id="trace-origin-mcp" class="badge badge-info">
                via MCP
              </span>
            </div>
            <span class="font-mono text-base-content truncate text-sm font-semibold">
              {Tracer.spec_label(@trace.spec)}
            </span>
          </div>
          <div class="stats stats-horizontal">
            <.stat
              title="Events"
              value={"#{@trace.events} / #{@trace.limits.max_events}"}
              value_class="font-mono text-lg"
            />
            <.stat title="Dropped" value={to_string(@trace.dropped)} value_class="font-mono text-lg" />
            <.stat
              title="Started"
              value={Calendar.strftime(@trace.started_at, "%H:%M:%S")}
              value_class="font-mono text-lg"
            />
          </div>
          <button
            :if={running?(@trace)}
            id="trace-stop"
            type="button"
            phx-click="stop"
            class="btn btn-error btn-sm ml-auto"
          >
            <.icon name="icon-square" class="size-3.5" /> Stop
          </button>
        </div>
      </section>

      <section id="trace-events-card" class="card bg-base-100 border-base-200 border shadow-sm">
        <div class="card-body gap-4 p-5">
          <div class="flex items-baseline justify-between">
            <h2 class="text-base-content text-sm font-semibold">Events</h2>
            <span class="font-mono text-base-content/70 text-xs">newest {shown_events()}</span>
          </div>
          <div class="overflow-x-auto">
            <table class="w-full table-fixed text-left">
              <thead>
                <tr class="border-base-content/10 border-b">
                  <th class="font-mono tracking-label text-base-content/70 w-32 px-2 pb-2 text-xs font-semibold uppercase">
                    Time (UTC)
                  </th>
                  <th class="font-mono tracking-label text-base-content/70 w-80 px-2 pb-2 text-xs font-semibold uppercase">
                    Process
                  </th>
                  <th class="font-mono tracking-label text-base-content/70 px-2 pb-2 text-xs font-semibold uppercase">
                    Call
                  </th>
                </tr>
              </thead>
              <tbody id="trace-events" phx-update="stream" class="divide-base-content/10 divide-y">
                <tr id="trace-events-empty" class="hidden only:table-row">
                  <td colspan="3" class="text-base-content/60 px-2 py-8 text-center text-sm">
                    No events yet. Start an example above.
                  </td>
                </tr>
                <tr
                  :for={{id, event} <- @streams.events}
                  id={id}
                  class="transition-colors hover:bg-base-200/60"
                >
                  <td class="font-mono text-base-content/70 px-2 py-2 text-xs">
                    {event_time(event.at)}
                  </td>
                  <td class="truncate px-2 py-2 text-xs">
                    <.display_pid pid={event.pid} />
                    <span class="font-mono text-base-content/60 ml-2">
                      {Tracer.process_label(event.process)}
                    </span>
                  </td>
                  <td
                    class="font-mono text-base-content truncate px-2 py-2 text-xs"
                    title={Tracer.call_text(event)}
                  >
                    {Tracer.call_text(event)}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>
    </div>
    """
  end

  @impl true
  def handle_event("start_example", %{"id" => id}, socket) do
    case Enum.find(examples(), &(&1.id == id)) do
      nil -> {:noreply, socket}
      example -> socket |> start_trace(example.spec) |> noreply()
    end
  end

  def handle_event("start_custom", %{"trace" => params}, socket) do
    socket = assign(socket, :form, to_form(params, as: :trace))

    case Tracer.parse_function(params["mfa"] || "") do
      {:ok, mfa} ->
        spec =
          Map.merge(mfa, %{capture: capture(params["capture"]), local: params["local"] == "true"})

        socket |> start_trace(spec) |> noreply()

      :error ->
        socket
        |> put_flash(:error, "Use Module.function/arity, e.g. Enum.map/2 or :ets.insert/2.")
        |> noreply()
    end
  end

  def handle_event("stop", _params, socket) do
    :ok = Tracer.stop()
    {:noreply, socket}
  end

  @impl true
  def handle_info({:trace_status, trace}, socket) do
    socket
    |> reset_on_new_trace(trace)
    |> assign(:trace, trace)
    |> noreply()
  end

  def handle_info({:trace_events, trace, events}, socket) do
    socket
    |> reset_on_new_trace(trace)
    |> assign(:trace, trace)
    |> stream(:events, events, at: 0, limit: @shown_events)
    |> noreply()
  end

  defp start_trace(socket, spec) do
    case Tracer.start(socket.assigns.session.node, spec) do
      {:ok, _trace} -> socket
      {:error, reason} -> put_flash(socket, :error, Tracer.error_message(reason))
    end
  end

  defp reset_on_new_trace(%{assigns: %{trace: %{id: id}}} = socket, %{id: id}), do: socket
  defp reset_on_new_trace(socket, _trace), do: stream(socket, :events, [], reset: true)

  defp examples, do: @examples
  defp shown_events, do: @shown_events

  defp running?(trace), do: match?(%{status: :running}, trace)

  defp capture("args"), do: :args
  defp capture(_arity), do: :arity

  defp event_time(at) do
    at
    |> DateTime.from_unix!(:microsecond)
    |> DateTime.truncate(:millisecond)
    |> Calendar.strftime("%H:%M:%S.%f")
  end
end
