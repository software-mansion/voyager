defmodule VoyagerWeb.TracingSessionLive do
  @moduledoc """
  Shows one tracing session, active or saved, and its run controls. It follows
  `Tracer.topic/0` and reloads a saved session once it stops being the active one.
  """

  use VoyagerWeb, :live_view

  alias Phoenix.LiveView.AsyncResult
  alias Voyager.Services.Tracer
  alias Voyager.Services.Tracer.Session
  alias VoyagerWeb.Components.TracingComponents
  alias VoyagerWeb.Formatters
  alias VoyagerWeb.TracingSessionLive.Stats

  @actions [:stop, :start, :load, :unload, :delete]
  @session_throttle_ms 250

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
  def render(assigns) do
    ~H"""
    <div
      id="tracing-session-page"
      class="mx-auto flex h-full max-w-screen-2xl flex-col gap-3 p-6 sm:p-8"
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
      </.async_result>

      <TracingComponents.confirm_modal
        :if={@confirm}
        id={"#{@confirm}-session-modal"}
        title={confirm_title(@confirm)}
        confirm_label={confirm_label(@confirm)}
        on_confirm={"confirm-#{@confirm}"}
        on_cancel="cancel-confirm"
      >
        <p :if={@confirm == :delete} class="text-base-content/70 mt-1 text-sm">
          Its {Formatters.format_integer(@trace_session.result.traces)} traces are deleted too. This cannot be undone.
        </p>
        <p :if={@confirm == :unload} class="text-base-content/70 mt-1 text-sm">
          It is not saved, so its parameters and traces are discarded. This cannot be undone.
        </p>
        <p :if={@confirm == :load} class="text-base-content/70 mt-1 text-sm">
          The session in the tracer is not saved, so its parameters and traces are discarded. This cannot be undone.
        </p>
      </TracingComponents.confirm_modal>
    </div>
    """
  end

  @impl true
  def handle_event("stop", _params, socket) do
    socket
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

  @impl true
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
    |> Stats.absorb(entries)
    |> noreply()
  end

  def handle_info(
        :put_queued_session,
        %{assigns: %{queued_session: %Session{} = session}} = socket
      ) do
    socket
    |> put_session(session, :active)
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

  defp gone(%{assigns: %{id: id}} = socket) when id < 0,
    do: leave(socket, :info, "The tracing session was closed.")

  defp gone(socket), do: load(socket)

  defp put_session(socket, session, mode) do
    shown = socket.assigns.trace_session.result

    socket
    |> assign(:trace_session, AsyncResult.ok(session))
    |> assign(:queued_session, nil)
    |> assign(:mode, mode)
    |> Stats.track(shown, session)
  end

  # Every trace batch carries the session; rendering each one swamps a slow client.
  defp queue_session(
         %{
           assigns: %{
             mode: :active,
             trace_session: %AsyncResult{result: %Session{status: status, config: config}}
           }
         } = socket,
         %Session{status: status, config: config} = session
       ) do
    if is_nil(socket.assigns.queued_session),
      do: Process.send_after(self(), :put_queued_session, @session_throttle_ms)

    assign(socket, :queued_session, session)
  end

  defp queue_session(socket, session), do: put_session(socket, session, :active)

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

  defp confirm_title(:delete), do: "Delete session"
  defp confirm_title(:unload), do: "Unload session"
  defp confirm_title(:load), do: "Replace unsaved session"

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
