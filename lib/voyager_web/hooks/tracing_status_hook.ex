defmodule VoyagerWeb.Hooks.TracingStatusHook do
  @moduledoc """
  LiveView hook that keeps `@tracing_session` set to the running tracing session
  of this Voyager (or `nil`) via PubSub, for the topbar indicator.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  alias Voyager.Services.Tracer

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Voyager.PubSub, Tracer.topic())
    end

    socket =
      socket
      |> assign(:tracing_session, running(active_session()))
      |> attach_hook(:tracing_status, :handle_info, &handle_tracing_status/2)

    {:cont, socket}
  end

  defp handle_tracing_status({:session_entries, session, _entries}, socket) do
    {:halt, assign(socket, :tracing_session, running(session))}
  end

  defp handle_tracing_status({:session_closed, _id}, socket) do
    {:halt, assign(socket, :tracing_session, nil)}
  end

  defp handle_tracing_status(_event, socket), do: {:cont, socket}

  # The Tracer blocks on the agent while starting or stopping a run; the broadcast that follows sets the state.
  defp active_session do
    Tracer.active()
  catch
    :exit, _reason -> nil
  end

  defp running(%{status: :running} = session), do: session
  defp running(_session), do: nil
end
