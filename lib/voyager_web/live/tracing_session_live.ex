defmodule VoyagerWeb.TracingSessionLive do
  @moduledoc """
  Shows one tracing session, active or saved, and its run controls. It follows
  `Tracer.topic/0` and reloads a saved session once it stops being the active one.
  `?seq=` opens the event details panel on that trace event.
  """

  use VoyagerWeb, :live_view

  alias Phoenix.LiveView.AsyncResult
  alias Voyager.Services.Tracer
  alias Voyager.Services.Tracer.CallPairing
  alias Voyager.Services.Tracer.Session
  alias VoyagerWeb.Components.TraceLogComponents
  alias VoyagerWeb.Components.TracingComponents
  alias VoyagerWeb.Formatters
  alias VoyagerWeb.Hooks.TermTreeHook
  alias VoyagerWeb.Hooks.TracingStatusHook
  alias VoyagerWeb.TracingSessionLive.Log
  alias VoyagerWeb.TracingSessionLive.Stats
  alias VoyagerWeb.Utils.URL

  on_mount TermTreeHook

  @actions [:stop, :start, :load, :unload, :delete]
  @term_open_depth 3

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Integer.parse(id) do
      {id, ""} ->
        socket
        |> assign(:active_nav, :tracing)
        |> assign(:id, id)
        |> assign(:mode, nil)
        |> assign(:trace_session, AsyncResult.loading())
        |> assign(:pending, nil)
        |> assign(:confirm, nil)
        |> assign(:queued_session, nil)
        |> assign(:flush_scheduled?, false)
        |> assign_call(nil, %AsyncResult{})
        |> TracingStatusHook.defer_puts()
        |> Log.init()
        |> Stats.init()
        |> subscribe_and_load()
        |> ok()

      _invalid ->
        socket
        |> leave(:error, "No such tracing session.")
        |> ok()
    end
  end

  @impl true
  def handle_params(%{"seq" => seq}, _uri, socket) do
    case parse_seq(seq) do
      nil -> patch_event(socket, nil, replace: true)
      seq -> open_event(socket, seq)
    end
    |> noreply()
  end

  def handle_params(_params, _uri, socket) do
    socket
    |> assign_call(nil, %AsyncResult{})
    |> noreply()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="tracing-session" class="relative flex h-full overflow-hidden">
      <div
        id="tracing-session-page"
        class="mx-auto flex h-full min-w-0 max-w-screen-2xl flex-1 flex-col gap-3 p-6 sm:p-8"
      >
        <.async_result :let={trace_session} assign={@trace_session}>
          <:loading>
            <.loading_state id="session-loading" message="Loading session…" />
          </:loading>
          <:failed>
            <.error_state id="session-error" message="Could not load the tracing session." />
          </:failed>
          <TracingComponents.session_bar
            trace_session={trace_session}
            mode={@mode}
            pending?={@pending != nil}
            show_back_arrow={@can_go_back?}
            connected_node={@session.node}
            stats={stats(trace_session, @rates, @now, @storage_limit_mb)}
            on_stop="stop"
            on_start="start"
            on_load="load"
            on_unload="unload"
            on_delete="delete"
          />
          <TracingComponents.empty_state :if={@mode == :active and is_nil(trace_session.config)} />
          <TraceLogComponents.log
            :if={trace_session.config}
            rows={@streams.entries}
            trace_session={trace_session}
            live?={@mode == :active and trace_session.status == :running}
            paused?={@paused?}
            new_count={@new_count}
            trace_rows={Log.trace_rows(@held)}
            oldest_seq={@oldest_seq}
            node={@session.node}
            node_name={@session.node_name}
            search={@search}
            search_form={@search_form}
            selection={@selection}
            on_select="select-event"
            on_pause="pause-log"
            on_resume="resume-log"
            on_older="load-older"
            on_ack="log-ack"
            on_search="search-log"
          />
        </.async_result>

        <TracingComponents.confirm_modal
          :if={@confirm}
          id={"#{@confirm}-session-modal"}
          title={confirm_title(@confirm)}
          confirm_label={confirm_label(@confirm)}
          on_confirm={"confirm-#{@confirm}"}
          on_cancel="cancel-confirm"
        >
          <p :if={@confirm == :stop} class="text-base-content/70 mt-1 text-sm">
            Tracing
            <span class="font-mono text-base-content">{TracingComponents.traced_mfa(
              @trace_session.result.config
            )}</span>
            on <span class="font-mono text-base-content">{@trace_session.result.node}</span>
            stops. {kept_copy(@trace_session.result.traces)}, and you can resume it later.
          </p>
          <p :if={@confirm == :delete} class="text-base-content/70 mt-1 text-sm">
            {deleted_copy(@trace_session.result.traces)} This cannot be undone.
          </p>
          <p :if={@confirm == :unload} class="text-base-content/70 mt-1 text-sm">
            It is not saved, so its parameters and traces are discarded. This cannot be undone.
          </p>
          <p :if={@confirm == :load} class="text-base-content/70 mt-1 text-sm">
            The session in the tracer is not saved, so its parameters and traces are discarded. This cannot be undone.
          </p>
        </TracingComponents.confirm_modal>
      </div>
      <TraceLogComponents.event_panel
        seq={@event_seq}
        call={@call}
        trace_session={@trace_session}
        node={@session.node}
        current_url={@current_url}
        term_states={@term_states}
        on_close="close-event-panel"
      />
    </div>
    """
  end

  @impl true
  def handle_event(
        "stop",
        _params,
        %{assigns: %{trace_session: %AsyncResult{result: %Session{status: :running}}}} = socket
      ) do
    socket
    |> assign(:confirm, :stop)
    |> noreply()
  end

  def handle_event("stop", _params, socket), do: noreply(socket)

  def handle_event("confirm-stop", _params, socket) do
    socket
    |> assign(:confirm, nil)
    |> run(:stop, fn -> Tracer.stop(:ui) end)
    |> noreply()
  end

  def handle_event("start", _params, socket) do
    socket
    |> run(:start, fn -> Tracer.start(:ui) end)
    |> noreply()
  end

  # A running session refuses the load as busy, so there is nothing to confirm.
  def handle_event(
        "load",
        _params,
        %{assigns: %{tracing_session: %Session{save: false, status: status}}} = socket
      )
      when status != :running do
    socket
    |> assign(:confirm, :load)
    |> noreply()
  end

  def handle_event("load", _params, socket) do
    id = socket.assigns.id

    socket
    |> run(:load, fn -> Tracer.load(id) end)
    |> noreply()
  end

  def handle_event("confirm-load", _params, socket) do
    id = socket.assigns.id

    socket
    |> assign(:confirm, nil)
    |> run(:load, fn -> Tracer.load(id) end)
    |> noreply()
  end

  def handle_event(
        "unload",
        _params,
        %{assigns: %{trace_session: %AsyncResult{result: %Session{save: false}}}} = socket
      ) do
    socket
    |> assign(:confirm, :unload)
    |> noreply()
  end

  def handle_event("unload", _params, socket) do
    socket
    |> run(:unload, &Tracer.close/0)
    |> noreply()
  end

  def handle_event("confirm-unload", _params, socket) do
    socket
    |> assign(:confirm, nil)
    |> run(:unload, &Tracer.close/0)
    |> noreply()
  end

  def handle_event("delete", _params, socket) do
    socket
    |> assign(:confirm, :delete)
    |> noreply()
  end

  def handle_event("cancel-confirm", _params, socket) do
    socket
    |> assign(:confirm, nil)
    |> noreply()
  end

  def handle_event("confirm-delete", _params, socket) do
    id = socket.assigns.id

    socket
    |> assign(:confirm, nil)
    |> run(:delete, fn -> Tracer.delete(id) end)
    |> noreply()
  end

  def handle_event("pause-log", _params, socket) do
    socket
    |> Log.pause()
    |> noreply()
  end

  def handle_event("resume-log", _params, socket) do
    socket
    |> Log.load()
    |> noreply()
  end

  def handle_event("load-older", _params, socket) do
    socket
    |> Log.older()
    |> noreply()
  end

  def handle_event("log-ack", _params, socket) do
    socket
    |> Log.ack()
    |> schedule_flush()
    |> noreply()
  end

  def handle_event("search-log", %{"search" => %{"query" => query} = params}, socket)
      when is_binary(query) do
    socket
    |> Log.search(params)
    |> noreply()
  end

  def handle_event("search-log", _params, socket), do: {:noreply, socket}

  def handle_event("select-event", params, socket) do
    case parse_seq(params["seq"]) do
      nil ->
        {:noreply, socket}

      seq ->
        socket
        |> select_event(seq)
        |> noreply()
    end
  end

  def handle_event("close-event-panel", _params, socket) do
    socket
    |> patch_event(nil, [])
    |> noreply()
  end

  @impl true
  def handle_async(:call, {:ok, {seq, {:ok, call}}}, %{assigns: %{event_seq: seq}} = socket) do
    socket
    |> put_call(call)
    |> noreply()
  end

  def handle_async(
        :call,
        {:ok, {seq, {:error, :not_found}}},
        %{assigns: %{event_seq: seq}} = socket
      ) do
    socket
    |> put_flash(:info, "That event is no longer in this session.")
    |> patch_event(nil, replace: true)
    |> noreply()
  end

  def handle_async(:call, {:exit, reason}, %{assigns: %{event_seq: seq}} = socket)
      when is_integer(seq) do
    socket
    |> assign(:call, AsyncResult.failed(socket.assigns.call, {:exit, reason}))
    |> noreply()
  end

  # The panel closed or moved on to another event since this lookup started.
  def handle_async(:call, _stale, socket), do: {:noreply, socket}

  # A broadcast for our id already ended the load, and is newer than its result.
  def handle_async(
        :session,
        _result,
        %{assigns: %{trace_session: %AsyncResult{loading: nil}}} = socket
      ),
      do: noreply(socket)

  def handle_async(:session, {:ok, {:ok, session, mode}}, socket) do
    socket
    |> put_session(session, mode)
    |> noreply()
  end

  def handle_async(:session, {:ok, {:error, :not_found}}, socket) do
    socket
    |> leave(:error, "No such tracing session.")
    |> noreply()
  end

  # A fresh result, not `failed(previous)`: the previous session's `ok?` would keep
  # its bar on screen and hide the failure.
  def handle_async(:session, {:exit, _reason}, socket) do
    socket
    |> assign(:confirm, nil)
    |> assign(:trace_session, AsyncResult.failed(%AsyncResult{}, :exit))
    |> noreply()
  end

  def handle_async(:delete, {:ok, {:ok, _row}}, socket) do
    socket
    |> leave(:info, "Tracing session deleted.")
    |> noreply()
  end

  def handle_async(name, result, socket) when name in @actions do
    socket = assign(socket, :pending, nil)

    case result do
      {:ok, {:error, reason}} ->
        socket
        |> put_flash(:error, format_error(reason))
        |> noreply()

      {:exit, _reason} ->
        socket
        |> put_flash(:error, format_error(:exit))
        |> noreply()

      {:ok, _ok} ->
        noreply(socket)
    end
  end

  @impl true
  def handle_info(
        {:session_activated, %Session{id: id} = session},
        %{assigns: %{id: id}} = socket
      ) do
    socket
    |> put_session(session, :active)
    |> noreply()
  end

  def handle_info(
        {:session_entries, %Session{id: id} = session, entries},
        %{assigns: %{id: id}} = socket
      ) do
    socket
    |> queue_session(session)
    |> Log.absorb(entries)
    |> Stats.absorb(entries)
    |> refresh_call(entries)
    |> schedule_flush()
    |> noreply()
  end

  # The indicator's queued update for another session waits for this view's flush too.
  def handle_info({:session_entries, _session, _entries}, socket) do
    socket
    |> schedule_flush()
    |> noreply()
  end

  # The ack schedules the next flush, so the session bar and indicator wait with the rows.
  def handle_info(:flush, %{assigns: %{awaiting_ack?: true}} = socket) do
    socket
    |> assign(:flush_scheduled?, false)
    |> noreply()
  end

  def handle_info(:flush, socket) do
    socket
    |> assign(:flush_scheduled?, false)
    |> put_queued_session()
    |> Log.flush()
    |> TracingStatusHook.put_queued()
    |> noreply()
  end

  def handle_info({:session_closed, id}, %{assigns: %{id: id}} = socket) do
    socket
    |> gone()
    |> noreply()
  end

  def handle_info({:session_activated, _other}, %{assigns: %{mode: mode}} = socket)
      when mode != :saved do
    socket
    |> gone()
    |> noreply()
  end

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
    |> assign(:trace_session, AsyncResult.loading(socket.assigns.trace_session))
    |> assign(:queued_session, nil)
    |> assign(:mode, nil)
    |> cancel_async(:session)
    |> start_async(:session, fn -> Tracer.session(id) end)
  end

  defp parse_seq(seq) when is_binary(seq) do
    case Integer.parse(seq) do
      {seq, ""} when seq >= 0 -> seq
      _invalid -> nil
    end
  end

  defp parse_seq(_seq), do: nil

  defp select_event(%{assigns: %{event_seq: seq}} = socket, seq), do: patch_event(socket, nil, [])
  defp select_event(%{assigns: %{event_seq: nil}} = socket, seq), do: patch_event(socket, seq, [])
  defp select_event(socket, seq), do: patch_event(socket, seq, replace: true)

  defp patch_event(socket, seq, opts) do
    url = socket.assigns.current_url

    to =
      if seq,
        do: URL.put_query_param(url, "seq", Integer.to_string(seq)),
        else: URL.drop_query_param(url, "seq")

    push_patch(socket, [to: to] ++ opts)
  end

  defp open_event(%{assigns: %{event_seq: seq}} = socket, seq), do: socket

  defp open_event(socket, seq) do
    socket
    |> assign_call(seq, AsyncResult.loading())
    |> look_up_call()
  end

  defp look_up_call(socket) do
    %{id: id, event_seq: seq} = socket.assigns
    start_async(socket, :call, fn -> {seq, Tracer.find_call(id, seq)} end)
  end

  defp put_call(socket, call) do
    %{event_seq: seq, call: shown} = socket.assigns

    socket
    |> put_terms(shown.result[:call_event], call.call_event)
    |> put_terms(shown.result[:outcome], call.outcome)
    |> assign_call(seq, AsyncResult.ok(shown, call))
  end

  defp assign_call(socket, seq, call) do
    socket
    |> assign(:event_seq, seq)
    |> assign(:call, call)
    |> assign(:selection, selection(seq, call))
  end

  # A refresh that found the outcome keeps the arguments' open branches.
  defp put_terms(socket, event, event), do: socket

  defp put_terms(socket, _shown, event) do
    event
    |> TraceLogComponents.panel_terms()
    |> Enum.reduce(socket, fn {id, _label, term}, acc ->
      TermTreeHook.put_term(acc, id, term, depth: @term_open_depth, open_all: true)
    end)
  end

  # Only the lookup's replay can tell this call's outcome from a nested call's with the same timing.
  defp refresh_call(
         %{
           assigns: %{
             call: %AsyncResult{ok?: true, result: %{call_event: %{} = call_event, outcome: nil}}
           }
         } = socket,
         entries
       ) do
    if Enum.any?(entries, &CallPairing.paired?(call_event, &1)),
      do: look_up_call(socket),
      else: socket
  end

  # A lookup still out may have read the log before these entries reached it.
  defp refresh_call(%{assigns: %{call: %AsyncResult{loading: true}}} = socket, entries) do
    if Enum.any?(entries, &match?(%{kind: :trace, type: type} when type != :call, &1)),
      do: look_up_call(socket),
      else: socket
  end

  defp refresh_call(socket, _entries), do: socket

  defp selection(nil, _call), do: nil

  defp selection(seq, %AsyncResult{result: result}) do
    partner = result && Enum.find([result.call_event, result.outcome], &(&1 && &1.seq != seq))
    %{selected: Log.entry_dom_id(%{seq: seq}), partner: partner && Log.entry_dom_id(partner)}
  end

  defp gone(%{assigns: %{id: id}} = socket) when id < 0,
    do: leave(socket, :info, "The tracing session was closed.")

  defp gone(socket), do: load(socket)

  defp put_session(socket, session, mode) do
    %{mode: shown_mode, trace_session: %AsyncResult{result: shown}} = socket.assigns

    socket =
      if shown_mode == mode and shown.config == session.config,
        do: socket,
        else: Log.load(socket)

    socket
    |> assign(:trace_session, AsyncResult.ok(session))
    |> assign(:queued_session, nil)
    |> assign(:mode, mode)
    |> Stats.track(shown, session)
    |> drop_stale_stop_confirm(session)
  end

  defp queue_session(
         %{
           assigns: %{
             mode: :active,
             trace_session: %AsyncResult{result: %Session{status: status, config: config}}
           }
         } = socket,
         %Session{status: status, config: config} = session
       ),
       do: assign(socket, :queued_session, session)

  defp queue_session(socket, session), do: put_session(socket, session, :active)

  defp put_queued_session(%{assigns: %{queued_session: nil}} = socket), do: socket
  defp put_queued_session(socket), do: put_session(socket, socket.assigns.queued_session, :active)

  defp schedule_flush(%{assigns: %{flush_scheduled?: true}} = socket), do: socket

  defp schedule_flush(socket) do
    Process.send_after(self(), :flush, TracingStatusHook.throttle_ms())
    assign(socket, :flush_scheduled?, true)
  end

  defp drop_stale_stop_confirm(%{assigns: %{confirm: :stop}} = socket, %Session{status: status})
       when status != :running,
       do: assign(socket, :confirm, nil)

  defp drop_stale_stop_confirm(socket, _session), do: socket

  defp run(socket, name, fun) do
    socket
    |> assign(:pending, name)
    |> start_async(name, fun)
  end

  defp leave(socket, kind, message) do
    socket
    |> put_flash(kind, message)
    |> push_navigate(to: sessions_path(socket.assigns.session))
  end

  defp sessions_path(%{node_name: node_name}), do: ~p"/node/#{node_name}/tracing"

  defp kept_copy(0), do: "No traces are kept"
  defp kept_copy(1), do: "Its 1 trace is kept"
  defp kept_copy(traces), do: "Its #{Formatters.format_integer(traces)} traces are kept"

  defp deleted_copy(0), do: "No traces are deleted."
  defp deleted_copy(1), do: "Its 1 trace is deleted too."

  defp deleted_copy(traces),
    do: "Its #{Formatters.format_integer(traces)} traces are deleted too."

  defp confirm_title(:stop), do: "Stop tracing"
  defp confirm_title(:delete), do: "Delete session"
  defp confirm_title(:unload), do: "Unload session"
  defp confirm_title(:load), do: "Replace unsaved session"

  defp confirm_label(:stop), do: "Stop"
  defp confirm_label(:delete), do: "Delete"
  defp confirm_label(:unload), do: "Unload"
  defp confirm_label(:load), do: "Load"

  defp stats(%Session{run_started_at: nil}, _rates, _now, _limit_mb), do: []
  defp stats(session, rates, now, limit_mb), do: Stats.cells(session, rates, now, limit_mb)

  defp format_error(:busy), do: "A tracing session is running. Stop it first."
  defp format_error(:not_found), do: "No such tracing session."
  defp format_error(:no_session), do: "This session is no longer active."
  defp format_error(:not_configured), do: "Set the session's parameters first."
  defp format_error(:changed), do: "The session was reconfigured meanwhile. Try again."

  defp format_error(:storage_limit),
    do: "Saved sessions use all their storage. Delete a saved session to resume."

  defp format_error({:refused, module}), do: "#{inspect(module)} cannot be traced."
  defp format_error({:not_loaded, module}), do: "#{inspect(module)} is not loaded on the node."
  defp format_error(:timeout), do: "The node did not respond in time."
  defp format_error(:noconnection), do: "Node is unreachable."

  defp format_error(reason) when reason in [:unknown_function, :no_function_matched],
    do: "No loaded function matches the traced pattern."

  defp format_error({:noproc, _pid}), do: "A traced process is no longer alive."
  defp format_error(:invalid_pid), do: "A traced PID is not valid."
  defp format_error({:tracer_down, _reason}), do: "The remote tracer crashed."
  defp format_error(:exit), do: "The tracer did not respond. Try again."
  defp format_error(reason), do: "Tracing failed: #{inspect(reason)}"
end
