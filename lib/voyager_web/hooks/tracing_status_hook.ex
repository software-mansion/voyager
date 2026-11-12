defmodule VoyagerWeb.Hooks.TracingStatusHook do
  @moduledoc """
  LiveView hook that keeps `@tracing_session` set to the active, configured tracing
  session of this Voyager (or `nil`) via PubSub, for the topbar indicator.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  alias Voyager.Services.Tracer
  alias Voyager.Services.Tracer.Config
  alias Voyager.Services.Tracer.Session

  @throttle_ms 250

  @doc """
  How long a running session's count-only updates are held before they are put. Every
  trace batch broadcasts the session, and rendering each one swamps a slow client.
  """
  @spec throttle_ms() :: pos_integer()
  def throttle_ms, do: @throttle_ms

  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> assign(:tracing_session, nil)
      |> assign(:queued_tracing_session, nil)
      |> assign(:tracing_flush_scheduled?, false)
      |> attach_hook(:tracing_status, :handle_info, &handle_tracing_status/2)
      |> attach_hook(:tracing_status_load, :handle_async, &handle_tracing_load/3)

    socket =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Voyager.PubSub, Tracer.session_topic())
        # Tracer.active/0 queues behind a run's start, which calls the remote node.
        start_async(socket, :tracing_session, &Tracer.active/0)
      else
        socket
      end

    {:cont, socket}
  end

  defp handle_tracing_status(
         {:session_updated, %Session{id: id, status: status, config: config} = session},
         %{assigns: %{tracing_session: %Session{id: id, status: status, config: config}}} = socket
       ) do
    if !socket.assigns.tracing_flush_scheduled?,
      do: Process.send_after(self(), :put_tracing_session, @throttle_ms)

    socket =
      socket
      |> assign(:queued_tracing_session, session)
      |> assign(:tracing_flush_scheduled?, true)

    {:halt, socket}
  end

  defp handle_tracing_status({:session_updated, session}, socket),
    do: {:halt, put_session(socket, session)}

  defp handle_tracing_status(:put_tracing_session, socket) do
    socket = assign(socket, :tracing_flush_scheduled?, false)

    case socket.assigns.queued_tracing_session do
      nil -> {:halt, socket}
      session -> {:halt, put_session(socket, session)}
    end
  end

  defp handle_tracing_status(_event, socket), do: {:cont, socket}

  defp handle_tracing_load(:tracing_session, {:ok, session}, socket),
    do: {:halt, assign(socket, :tracing_session, shown(session))}

  defp handle_tracing_load(:tracing_session, {:exit, _reason}, socket), do: {:halt, socket}

  defp handle_tracing_load(_name, _result, socket), do: {:cont, socket}

  # A broadcast is newer than the load still in flight, so the load is dropped.
  defp put_session(socket, session) do
    socket
    |> cancel_async(:tracing_session)
    |> assign(:tracing_session, shown(session))
    |> assign(:queued_tracing_session, nil)
  end

  defp shown(%Session{config: %Config{}} = session), do: session
  defp shown(_session), do: nil
end
