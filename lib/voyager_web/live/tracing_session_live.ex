defmodule VoyagerWeb.TracingSessionLive do
  @moduledoc """
  Shows one tracing session, active or saved, and its run controls. It follows
  `Tracer.topic/0` and reloads a saved session once it stops being the active one.
  """

  use VoyagerWeb, :live_view

  alias Voyager.Services.Tracer
  alias Voyager.Services.Tracer.Config
  alias Voyager.Services.Tracer.Session
  alias VoyagerWeb.Components.TracingComponents
  alias VoyagerWeb.Formatters

  @actions [:stop, :start, :load, :delete]
  @row_limit 200
  @flush_ms 250

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Integer.parse(id) do
      {id, ""} ->
        socket
        |> assign(:active_nav, :tracing)
        |> assign(:id, id)
        |> assign(:trace_session, nil)
        |> assign(:mode, nil)
        |> assign(:now, nil)
        |> assign(:loading?, false)
        |> assign(:failed?, false)
        |> assign(:pending, nil)
        |> assign(:confirm_delete?, false)
        |> assign(:paused?, false)
        |> assign(:new_count, 0)
        |> assign(:buffer, [])
        |> assign(:flush_scheduled?, false)
        |> assign(:newest_seq, nil)
        |> assign(:oldest_seq, 0)
        |> assign(:held_kinds, [])
        |> stream_configure(:entries, dom_id: &entry_dom_id/1)
        |> stream(:entries, [])
        |> subscribe_and_load()
        |> ok()

      _invalid ->
        socket
        |> leave(:error, "No such tracing session.")
        |> ok()
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="tracing-session-page"
      class="mx-auto flex h-full max-w-screen-2xl flex-col gap-3 p-6 sm:p-8"
    >
      <.error_state :if={@failed?} id="session-error" message="Could not load the tracing session." />
      <.loading_state
        :if={!@failed? and is_nil(@trace_session)}
        id="session-loading"
        message="Loading session…"
      />

      <div
        :if={!@failed? and @trace_session}
        id="session-bar"
        class="card bg-base-100 border-base-200 text-base-content flex-none border shadow-sm"
      >
        <div class="flex items-center gap-3 px-4 py-3">
          <.link
            navigate={~p"/node/#{@session.node_name}/tracing"}
            id="session-back"
            aria-label="Back to sessions"
            class="btn btn-ghost btn-square toolbar-btn-sm text-base-content shrink-0"
          >
            <.icon name="icon-arrow-left" class="toolbar-icon-sm" />
          </.link>
          <span
            id="session-status"
            data-tone={TracingComponents.tone(@trace_session)}
            class="flex shrink-0 items-center gap-2"
          >
            <span class="relative flex h-2 w-2 shrink-0">
              <span
                :if={@trace_session.status == :running}
                class="bg-success absolute inline-flex h-full w-full animate-ping rounded-full opacity-75"
              ></span>
              <span class={[
                "relative inline-flex h-2 w-2 rounded-full",
                TracingComponents.tone_class(TracingComponents.tone(@trace_session), :dot)
              ]}></span>
            </span>
            <span class="text-sm font-semibold">
              {String.capitalize(TracingComponents.state(@trace_session))}
            </span>
            <span id="session-elapsed" class="font-mono text-base-content/70 text-xs">
              {elapsed(@trace_session, @now)}
            </span>
          </span>
          <span id="session-mfa" class="font-mono text-base-content shrink-0 text-sm font-medium">
            {if @trace_session.config,
              do: TracingComponents.traced_mfa(@trace_session.config),
              else: "New session"}
          </span>
          <div class="flex min-w-0 flex-1 items-center gap-2">
            <span
              :for={{key, label, value} <- chips(@trace_session)}
              id={"session-chip-#{key}"}
              class="bg-primary/10 flex min-w-0 items-center gap-1.5 rounded-lg px-2 py-1"
            >
              <span class="font-mono tracking-label text-primary shrink-0 text-xs font-semibold uppercase">
                {label}
              </span>
              <span class="font-mono truncate text-xs">{value}</span>
            </span>
          </div>
          <div class="flex shrink-0 items-center gap-2">
            <button
              :if={@mode == :active and @trace_session.config}
              type="button"
              id="session-edit"
              disabled
              title={if @trace_session.status == :running, do: "Stop the session to edit"}
              class="btn btn-sm"
            >
              <.icon name="icon-pencil" class="size-3.5" /> Edit
            </button>
            <button
              :if={@mode == :active and @trace_session.status == :running}
              type="button"
              id="session-stop"
              phx-click="stop"
              disabled={@pending != nil}
              class="btn btn-sm bg-error/10 border-error/30 text-error shadow-none"
            >
              <.icon name="icon-square" class="size-3.5" /> Stop
            </button>
            <button
              :if={@mode == :active and @trace_session.status == :stopped}
              type="button"
              id="session-resume"
              phx-click="start"
              disabled={@pending != nil}
              class="btn btn-sm btn-primary"
            >
              <.icon name="icon-play" class="size-3.5" /> Resume
            </button>
            <button
              :if={@mode == :active and @trace_session.status == :idle}
              type="button"
              id="session-start"
              phx-click="start"
              disabled={@pending != nil or is_nil(@trace_session.config)}
              class="btn btn-sm btn-primary"
            >
              <.icon name="icon-play" class="size-3.5" /> Start
            </button>
            <button
              :if={@mode == :saved}
              type="button"
              id="session-load"
              phx-click="load"
              disabled={@pending != nil}
              class="btn btn-sm"
            >
              <.icon name="icon-log-in" class="size-3.5" /> Load into tracer
            </button>
            <button
              :if={@mode == :saved}
              type="button"
              id="session-delete"
              phx-click="delete"
              disabled={@pending != nil}
              aria-label="Delete session"
              class="btn btn-sm btn-square text-error"
            >
              <.icon name="icon-trash" class="size-3.5" />
            </button>
          </div>
        </div>
      </div>

      <div
        :if={!@failed? and @mode == :active and is_nil(@trace_session.config)}
        id="session-empty"
        class="card bg-base-100 border-base-200 flex min-h-0 flex-1 flex-col items-center justify-center gap-3 border shadow-sm"
      >
        <.icon name="icon-binoculars" class="text-base-content/60 size-8" />
        <div class="text-center">
          <p class="text-base-content font-semibold">Nothing to trace yet</p>
          <p class="text-base-content/70 mt-0.5 text-sm">
            Pick a function and at least one limit to start this session.
          </p>
        </div>
        <button type="button" id="session-set-parameters" disabled class="btn btn-primary btn-sm">
          <.icon name="icon-pencil" class="size-3.5" /> Set parameters
        </button>
      </div>

      <TracingComponents.log
        :if={(!@failed? and @trace_session) && @trace_session.config}
        rows={@streams.entries}
        trace_session={@trace_session}
        live?={@mode == :active and @trace_session.status == :running}
        paused?={@paused?}
        new_count={@new_count}
        trace_rows={Enum.count(@held_kinds, &(&1 == :trace))}
        oldest_seq={@oldest_seq}
        pid_href={pid_href(@trace_session, @session)}
        on_pause="pause-log"
        on_resume="resume-log"
        on_older="load-older"
      />

      <div
        :if={@confirm_delete?}
        id="delete-session-modal"
        role="dialog"
        aria-modal="true"
        aria-labelledby="delete-session-modal-title"
        class="modal modal-open"
      >
        <.focus_wrap
          id="delete-session-modal-box"
          phx-mounted={JS.focus_first()}
          class="modal-box border-base-300 max-w-md border shadow-2xl"
        >
          <h2
            id="delete-session-modal-title"
            class="text-base-content text-lg font-semibold tracking-tight"
          >
            Delete session
          </h2>
          <p class="text-base-content/70 mt-1 text-sm">
            Its {Formatters.format_integer(@trace_session.traces)} traces are deleted too. This cannot be undone.
          </p>
          <div class="modal-action">
            <button
              type="button"
              id="delete-session-cancel"
              phx-click="cancel-delete"
              class="btn btn-ghost"
            >
              Cancel
            </button>
            <button
              type="button"
              id="delete-session-confirm"
              phx-click="confirm-delete"
              class="btn btn-error"
            >
              Delete
            </button>
          </div>
        </.focus_wrap>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("stop", _params, socket),
    do: socket |> run(:stop, fn -> Tracer.stop(:ui) end) |> noreply()

  def handle_event("start", _params, socket),
    do: socket |> run(:start, fn -> Tracer.start(:ui) end) |> noreply()

  def handle_event("load", _params, socket) do
    id = socket.assigns.id
    socket |> run(:load, fn -> Tracer.load(id) end) |> noreply()
  end

  def handle_event("delete", _params, socket),
    do: socket |> assign(:confirm_delete?, true) |> noreply()

  def handle_event("cancel-delete", _params, socket),
    do: socket |> assign(:confirm_delete?, false) |> noreply()

  def handle_event("confirm-delete", _params, socket) do
    id = socket.assigns.id

    socket
    |> assign(:confirm_delete?, false)
    |> run(:delete, fn -> Tracer.delete(id) end)
    |> noreply()
  end

  def handle_event("pause-log", _params, socket), do: socket |> pause() |> noreply()

  def handle_event("resume-log", _params, socket), do: socket |> load_page() |> noreply()

  def handle_event("load-older", _params, socket) do
    %{id: id, oldest_seq: before} = socket.assigns

    socket
    |> pause_running()
    |> start_async(:older, fn -> Tracer.entries(id, before: before) end)
    |> noreply()
  end

  @impl true
  # A broadcast for our id already ended the load, and is newer than its result.
  def handle_async(:session, _result, %{assigns: %{loading?: false}} = socket),
    do: noreply(socket)

  def handle_async(:session, {:ok, {:ok, session, mode}}, socket),
    do: socket |> put_session(session, mode) |> noreply()

  def handle_async(:session, {:ok, {:error, :not_found}}, socket),
    do: socket |> leave(:error, "No such tracing session.") |> noreply()

  def handle_async(:session, {:exit, _reason}, socket) do
    socket
    |> assign(:loading?, false)
    |> assign(:failed?, true)
    |> noreply()
  end

  def handle_async(:page, {:ok, {:ok, page}}, socket),
    do: socket |> put_page(page) |> flush() |> noreply()

  def handle_async(:older, {:ok, {:ok, page}}, socket),
    do: socket |> put_older(page) |> noreply()

  def handle_async(:page, _failed, socket),
    do: socket |> pause() |> put_flash(:error, "Could not load the events.") |> noreply()

  def handle_async(:older, _failed, socket), do: noreply(socket)

  def handle_async(:delete, {:ok, {:ok, _row}}, socket),
    do: socket |> leave(:info, "Tracing session deleted.") |> noreply()

  def handle_async(name, result, socket) when name in @actions do
    socket = assign(socket, :pending, nil)

    case result do
      {:ok, {:error, reason}} -> socket |> put_flash(:error, error_message(reason)) |> noreply()
      {:exit, _reason} -> socket |> put_flash(:error, error_message(:exit)) |> noreply()
      {:ok, _ok} -> noreply(socket)
    end
  end

  @impl true
  def handle_info(
        {:session_activated, %Session{id: id} = session},
        %{assigns: %{id: id}} = socket
      ),
      do: socket |> put_session(session, :active) |> noreply()

  def handle_info(
        {:session_entries, %Session{id: id} = session, entries},
        %{assigns: %{id: id}} = socket
      ),
      do: socket |> put_session(session, :active) |> buffer(entries) |> noreply()

  def handle_info(:flush_log, socket),
    do: socket |> assign(:flush_scheduled?, false) |> flush() |> noreply()

  def handle_info({:session_closed, id}, %{assigns: %{id: id}} = socket),
    do: socket |> gone() |> noreply()

  def handle_info({:session_activated, _other}, %{assigns: %{mode: mode}} = socket)
      when mode != :saved,
      do: socket |> gone() |> noreply()

  def handle_info(_message, socket), do: noreply(socket)

  defp subscribe_and_load(socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Voyager.PubSub, Tracer.topic())
      load(socket)
    else
      socket
    end
  end

  defp load(socket) do
    id = socket.assigns.id

    socket
    |> assign(:loading?, true)
    |> assign(:mode, nil)
    |> cancel_async(:session)
    |> start_async(:session, fn -> Tracer.session(id) end)
  end

  defp gone(%{assigns: %{id: id}} = socket) when id < 0,
    do: leave(socket, :info, "The tracing session was closed.")

  defp gone(socket), do: load(socket)

  defp put_session(socket, session, mode) do
    %{mode: shown_mode, trace_session: shown} = socket.assigns

    socket =
      if shown_mode == mode and shown.config == session.config,
        do: socket,
        else: load_page(socket)

    socket
    |> assign(:loading?, false)
    |> assign(:trace_session, session)
    |> assign(:mode, mode)
    |> assign(:failed?, false)
    |> assign(:now, DateTime.utc_now())
  end

  defp load_page(socket) do
    id = socket.assigns.id

    socket
    |> assign(:newest_seq, nil)
    |> assign(:paused?, false)
    |> assign(:new_count, 0)
    |> start_async(:page, fn -> Tracer.entries(id) end)
  end

  defp put_page(socket, %{entries: entries, truncated?: truncated?}) do
    rows = with_evicted(entries, truncated?, nil)

    # An older page still in flight was fetched below the stream this page replaces.
    socket
    |> cancel_async(:older)
    |> stream(:entries, rows, reset: true)
    |> assign(:newest_seq, newest_seq(entries))
    |> assign(:oldest_seq, oldest_seq(entries))
    |> assign(:held_kinds, kinds(rows))
  end

  defp put_older(socket, %{entries: entries, truncated?: truncated?}) do
    rows = with_evicted(entries, truncated?, socket.assigns.oldest_seq)

    socket
    |> stream(:entries, rows, at: -1)
    |> assign(:oldest_seq, oldest_seq(entries))
    |> update(:held_kinds, &(&1 ++ kinds(rows)))
  end

  defp newest_seq([]), do: -1
  defp newest_seq([%{seq: seq} | _older]), do: seq

  defp oldest_seq([]), do: 0
  defp oldest_seq(entries), do: List.last(entries).seq

  defp with_evicted(entries, false, _newer_seq), do: entries

  defp with_evicted(entries, true, newer_seq) do
    {rows, _acc} =
      Enum.flat_map_reduce(entries, newer_seq, fn
        entry, newer when is_integer(newer) and newer - entry.seq > 1 ->
          {[%{kind: :evicted, seq: entry.seq + 1}, entry], :marked}

        entry, :marked ->
          {[entry], :marked}

        entry, _newer ->
          {[entry], entry.seq}
      end)

    rows
  end

  defp buffer(socket, []), do: socket

  defp buffer(%{assigns: %{paused?: true}} = socket, entries),
    do: update(socket, :new_count, &(&1 + count_traces(entries)))

  defp buffer(socket, entries) do
    socket = update(socket, :buffer, &Enum.take(&1 ++ entries, -@row_limit))

    if socket.assigns.flush_scheduled? do
      socket
    else
      Process.send_after(self(), :flush_log, @flush_ms)
      assign(socket, :flush_scheduled?, true)
    end
  end

  # Until the first page lands, the buffer cannot tell which entries that page already holds.
  defp flush(%{assigns: %{paused?: false, newest_seq: newest_seq}} = socket)
       when is_integer(newest_seq) do
    case Enum.filter(socket.assigns.buffer, &(&1.seq > newest_seq)) do
      [] ->
        assign(socket, :buffer, [])

      rows ->
        newest_seq = List.last(rows).seq

        socket
        |> stream(:entries, rows, at: 0, limit: @row_limit)
        |> assign(:buffer, [])
        |> assign(:newest_seq, newest_seq)
        |> update(:held_kinds, &Enum.take(Enum.reverse(kinds(rows)) ++ &1, @row_limit))
        |> update(:oldest_seq, &max(&1, newest_seq - @row_limit + 1))
    end
  end

  defp flush(socket), do: socket

  defp pause(socket) do
    socket
    |> assign(:paused?, true)
    |> assign(:new_count, count_traces(socket.assigns.buffer))
    |> assign(:buffer, [])
  end

  defp pause_running(
         %{assigns: %{mode: :active, paused?: false, trace_session: %{status: :running}}} = socket
       ),
       do: pause(socket)

  defp pause_running(socket), do: socket

  defp kinds(rows), do: Enum.map(rows, & &1.kind)

  defp count_traces(entries), do: Enum.count(entries, &(&1.kind == :trace))

  defp entry_dom_id(%{kind: :evicted, seq: seq}), do: "entry-evicted-#{seq}"
  defp entry_dom_id(%{seq: seq}), do: "entry-#{seq}"

  defp pid_href(%Session{node: node}, %{node: node, node_name: node_name}),
    do: &~p"/node/#{node_name}/processes/#{Formatters.format_pid(&1)}"

  defp pid_href(_trace_session, _node_session), do: nil

  defp run(socket, name, fun), do: socket |> assign(:pending, name) |> start_async(name, fun)

  defp leave(socket, kind, message) do
    path = ~p"/node/#{socket.assigns.session.node_name}/tracing"

    socket
    |> put_flash(kind, message)
    |> push_navigate(to: path)
  end

  defp elapsed(%Session{status: :running, run_started_at: %DateTime{} = started}, now),
    do: format_elapsed(DateTime.diff(now, started))

  defp elapsed(%Session{status: :stopped, run_started_at: %DateTime{} = started} = session, _now)
       when not is_nil(session.stopped_at),
       do: format_elapsed(DateTime.diff(session.stopped_at, started))

  defp elapsed(_session, _now), do: nil

  defp format_elapsed(seconds),
    do:
      "#{div(seconds, 60)}:#{seconds |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"

  defp chips(%Session{config: nil, save: save}),
    do: [{:storage, "Storage", if(save, do: "Saved", else: "Not saved")}]

  defp chips(%Session{config: %Config{} = config}) do
    [
      {:where, "Where", "#{processes(config)} · #{config.scope}"},
      {:capture, "Capture", capture(config)},
      {:stop_after, "Stop after", stop_after(config)}
    ]
  end

  defp processes(%Config{processes: :all}), do: "All processes"
  defp processes(%Config{processes: :existing}), do: "Existing processes"
  defp processes(%Config{processes: :new}), do: "New processes"
  defp processes(%Config{processes: :pids, pids: pids}), do: "#{length(pids)} pids"

  defp capture(config) do
    captured =
      if config.capture == :args,
        do: "Args ≤ #{Formatters.format_integer(config.budget)}",
        else: "Arity"

    if config.return_trace, do: captured <> " + returns", else: captured
  end

  defp stop_after(config) do
    [
      config.max_events && Formatters.format_integer(config.max_events),
      config.max_rate && "#{Formatters.format_integer(config.max_rate)}/s",
      config.max_time_ms && format_time_limit(config.max_time_ms)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp format_time_limit(ms) when rem(ms, 1_000) != 0, do: "#{Formatters.format_integer(ms)} ms"
  defp format_time_limit(ms) when rem(ms, 60_000) != 0, do: "#{div(ms, 1_000)} s"
  defp format_time_limit(ms) when ms < 3_600_000, do: "#{div(ms, 60_000)} min"
  defp format_time_limit(ms), do: "#{div(ms, 3_600_000)} h"

  defp error_message(:busy), do: "A tracing session is running. Stop it first."
  defp error_message(:not_found), do: "No such tracing session."
  defp error_message(:no_session), do: "This session is no longer active."
  defp error_message(:not_configured), do: "Set the session's parameters first."
  defp error_message(:changed), do: "The session was reconfigured meanwhile. Try again."
  defp error_message({:refused, module}), do: "#{inspect(module)} cannot be traced."
  defp error_message({:not_loaded, module}), do: "#{inspect(module)} is not loaded on the node."
  defp error_message(:timeout), do: "The node did not respond in time."
  defp error_message(:noconnection), do: "Node is unreachable."

  defp error_message(reason) when reason in [:unknown_function, :no_function_matched],
    do: "No loaded function matches the traced pattern."

  defp error_message({:noproc, _pid}), do: "A traced process is no longer alive."
  defp error_message(:invalid_pid), do: "A traced PID is not valid."
  defp error_message({:tracer_down, _reason}), do: "The remote tracer crashed."
  defp error_message(:exit), do: "The tracer did not respond. Try again."
  defp error_message(reason), do: "Tracing failed: #{inspect(reason)}"
end
