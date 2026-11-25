defmodule VoyagerWeb.Hooks.DemoNodeHook do
  @moduledoc false

  import Phoenix.LiveView
  import Phoenix.Component

  alias Voyager.Services.DemoNode
  alias VoyagerWeb.ConnectLive.DirectConnect

  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> subscribe()
      |> assign(:demo_running?, DemoNode.running?())
      |> attach_hook(:demo_running, :handle_info, &handle_demo_stopped/2)

    {:cont, socket}
  end

  def on_mount(:notify_stopped, _params, _session, socket) do
    socket =
      socket
      |> subscribe()
      |> attach_hook(:demo_stopped, :handle_info, &notify_stopped/2)

    {:cont, socket}
  end

  defp subscribe(socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Voyager.PubSub, DemoNode.topic())
    end

    socket
  end

  defp handle_demo_stopped({:demo_stopped, _reason}, socket) do
    {:halt, assign(socket, :demo_running?, false)}
  end

  defp handle_demo_stopped(_event, socket), do: {:cont, socket}

  defp notify_stopped({:demo_stopped, :idle_timeout}, socket) do
    {:halt,
     put_stopped_flash(socket, :info, "The demo node stopped after being idle. Start it again.")}
  end

  defp notify_stopped({:demo_stopped, :halted}, socket) do
    {:halt,
     put_stopped_flash(socket, :error, "The demo node stopped unexpectedly. Start it again.")}
  end

  defp notify_stopped(_event, socket), do: {:cont, socket}

  defp put_stopped_flash(socket, kind, msg) do
    send_update(DirectConnect, id: "direct-connect", demo_stopped: true)
    put_flash(socket, kind, msg)
  end
end
