defmodule VoyagerWeb.ConnectLive do
  use VoyagerWeb, :live_view

  alias Voyager.NodeSession
  alias VoyagerWeb.ConnectComponents

  @impl true
  def mount(_params, _session, socket) do
    connected_session = NodeSession.current()

    socket
    |> assign(:proxy_epmd_active?, Voyager.ProxyEpmd.active?())
    |> assign(:connected_session, connected_session)
    |> assign(:mode, connection_mode(connected_session))
    |> assign(:connecting?, false)
    |> ok()
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :mode_disabled_reason, mode_disabled_reason(assigns))

    ~H"""
    <div class="bg-base-200 h-full overflow-y-auto">
      <div class="min-w-96 flex min-h-full items-center justify-center p-4">
        <div class="card bg-base-100 w-full max-w-lg shadow-xl">
          <div class="card-body gap-0 p-10">
            <div class="mb-7 flex items-center gap-3">
              <.logo />
              <div class="text-base-content text-lg font-semibold tracking-tight">Voyager</div>
              <.link
                id="open-settings"
                href={~p"/settings?#{[return_to: "/"]}"}
                title="Settings"
                class="btn btn-ghost btn-square toolbar-btn text-base-content/60 ml-auto hover:text-base-content"
              >
                <.icon name="icon-settings" class="toolbar-icon" />
              </.link>
            </div>
            <ConnectComponents.connected_indicator session={@connected_session} />

            <div class="mb-6">
              <h1 class="text-base-content mb-4 text-2xl font-semibold tracking-tight">
                Connect to a node
              </h1>
              <h4 class="font-mono tracking-label text-base-content/70 mb-2 text-xs uppercase">
                Connection type:
              </h4>
              <ConnectComponents.mode_toggle
                mode={@mode}
                disabled={not is_nil(@mode_disabled_reason)}
                reason={@mode_disabled_reason}
              >
                <:disabled_reason :if={@mode_disabled_reason == :connected}>
                  Cannot change mode while connected
                </:disabled_reason>
                <:disabled_reason :if={@mode_disabled_reason == :connecting}>
                  Cannot change mode while connecting
                </:disabled_reason>
                <:disabled_reason :if={@mode_disabled_reason == :proxy_epmd_inactive}>
                  Cannot change to SSH tunnel mode while <strong>proxy_epmd</strong>
                  module is not active
                </:disabled_reason>
              </ConnectComponents.mode_toggle>
              <p
                :if={@mode == :direct}
                class="font-mono text-base-content/70"
              >
                Inspect node on your machine.
              </p>
              <p
                :if={@mode == :ssh}
                class="font-mono text-base-content/70"
              >
                Tunnel into a remote machine to reach its node.
              </p>
            </div>

            <div class={@mode != :direct && "hidden"}>
              <.live_component
                module={VoyagerWeb.ConnectLive.DirectConnect}
                id="direct-connect"
                connected?={not is_nil(@connected_session)}
              />
            </div>
            <div class={(@mode != :ssh or !@proxy_epmd_active?) && "hidden"}>
              <.live_component
                module={VoyagerWeb.ConnectLive.SshConnect}
                id="ssh-connect"
                connected?={not is_nil(@connected_session)}
              />
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("switch_mode", %{"mode" => "direct"}, socket) do
    {:noreply, assign(socket, :mode, :direct)}
  end

  def handle_event("switch_mode", %{"mode" => "ssh"}, socket) do
    {:noreply, assign(socket, :mode, :ssh)}
  end

  @impl true
  def handle_info({:node_connected, _node}, socket) do
    connected_session = NodeSession.current()

    socket
    |> assign(:connected_session, connected_session)
    |> assign(:mode, connection_mode(connected_session))
    |> noreply()
  end

  def handle_info({event, _node}, socket) when event in [:node_disconnected, :nodedown] do
    {:noreply, assign(socket, :connected_session, nil)}
  end

  def handle_info({:ssh_connecting, connecting?}, socket) do
    {:noreply, assign(socket, :connecting?, connecting?)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp mode_disabled_reason(assigns) do
    cond do
      not is_nil(assigns.connected_session) -> :connected
      assigns.connecting? -> :connecting
      not assigns.proxy_epmd_active? -> :proxy_epmd_inactive
      true -> nil
    end
  end

  defp connection_mode(%NodeSession.Session{connector: connector}) do
    ui_mode(connector.name())
  end

  defp connection_mode(nil) do
    ui_mode(NodeSession.last_via())
  end

  defp ui_mode(:ssh), do: :ssh
  defp ui_mode(_), do: :direct
end
