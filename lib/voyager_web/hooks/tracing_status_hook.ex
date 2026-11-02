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

  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> assign(:tracing_session, nil)
      |> attach_hook(:tracing_status, :handle_info, &handle_tracing_status/2)
      |> attach_hook(:tracing_status_load, :handle_async, &handle_tracing_load/3)

    socket =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Voyager.PubSub, Tracer.topic())
        # Tracer.active/0 queues behind a run's start, which calls the remote node.
        start_async(socket, :tracing_session, &Tracer.active/0)
      else
        socket
      end

    {:cont, socket}
  end

  defp handle_tracing_status({:session_entries, session, _entries}, socket),
    do: {:halt, put_session(socket, session)}

  defp handle_tracing_status({:session_activated, session}, socket),
    do: {:halt, put_session(socket, session)}

  defp handle_tracing_status({:session_closed, _id}, socket),
    do: {:halt, put_session(socket, nil)}

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
  end

  defp shown(%Session{config: %Config{}} = session), do: session
  defp shown(_session), do: nil
end
