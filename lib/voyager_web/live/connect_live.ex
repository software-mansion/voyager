defmodule VoyagerWeb.ConnectLive do
  use VoyagerWeb, :live_view

  alias Voyager.Actions.Connections, as: ConnectionActions
  alias Voyager.NodeSession
  alias Voyager.Queries.Connections, as: ConnectionQueries
  alias VoyagerWeb.ConnectComponents
  alias VoyagerWeb.FormSchemas.ConnectionParams

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Voyager.PubSub, NodeSession.topic())
    end

    socket
    |> reset_connections()
    |> assign(:form, empty_form())
    |> assign(:show_distribution_settings?, false)
    |> assign(:show_cookie, false)
    |> assign(:connected_session, NodeSession.current())
    |> assign(:mode, :direct)
    |> ok()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="bg-base-200 h-full overflow-y-auto">
      <div class="flex min-h-full items-center justify-center p-4">
        <div class="card bg-base-100 w-full max-w-lg shadow-xl">
          <div class="card-body gap-0 p-10">
            <div class="mb-7 flex items-center gap-3">
              <.logo />
              <div class="text-base-content text-lg font-semibold tracking-tight">Voyager</div>
              <button
                type="button"
                id="open-distribution-settings"
                phx-click="open_distribution_settings"
                title="Distribution settings"
                class="btn btn-ghost btn-square btn-sm text-base-content/50 ml-auto hover:text-base-content"
              >
                <.icon name="icon-settings" class="size-4" />
              </button>
            </div>
            <div class="mb-6">
              <h1 class="text-base-content text-2xl font-semibold tracking-tight">
                Connect to a node
              </h1>
              <p :if={@mode == :direct} class="text-base-content/60 mt-1 text-sm">
                Enter the node name and Erlang cookie to inspect a local or remote BEAM.
              </p>
              <p :if={@mode == :ssh} class="text-base-content/60 mt-1 text-sm">
                Connect to a remote node through an SSH gateway tunnel.
              </p>
            </div>

            <ConnectComponents.connected_indicator session={@connected_session} />

            <%!-- SSH feature seam: delete this toggle + switch_mode/2 + the SSH
                 live_component below to remove SSH connections entirely. --%>
            <form phx-change="switch_mode" id="ssh-mode-toggle" class="mb-6">
              <div class="join w-full">
                <input
                  type="radio"
                  name="mode"
                  value="direct"
                  aria-label="Direct"
                  id="mode-direct"
                  checked={@mode == :direct}
                  disabled={not is_nil(@connected_session)}
                  class="join-item btn btn-soft btn-sm font-mono flex-1 text-xs transition-colors checked:text-primary-content disabled:text-base-content/60"
                />
                <input
                  type="radio"
                  name="mode"
                  value="ssh"
                  aria-label="SSH Tunnel"
                  id="mode-ssh"
                  checked={@mode == :ssh}
                  disabled={not is_nil(@connected_session)}
                  class="join-item btn btn-soft btn-sm font-mono flex-1 text-xs transition-colors checked:text-primary-content disabled:text-base-content/60"
                />
              </div>
            </form>

            <div :if={@mode == :direct}>
              <ConnectComponents.connect_form
                form={@form}
                show_cookie={@show_cookie}
                disabled={not is_nil(@connected_session)}
              />

              <div :if={@has_pinned} class="border-base-300 mt-7 border-t pt-5">
                <p class="font-mono tracking-label text-base-content/50 mb-2.5 text-xs uppercase">
                  Favourites
                </p>
                <ul id="pinned-connections" phx-update="stream" class="-mx-2 flex flex-col gap-0.5">
                  <li :for={{id, conn} <- @streams.pinned_connections} id={id} class="list-none">
                    <ConnectComponents.connection_row conn={conn} pinned={true} />
                  </li>
                </ul>
              </div>

              <div
                :if={@has_recent}
                class={["border-base-300 border-t pt-5", if(@has_pinned, do: "mt-3", else: "mt-7")]}
              >
                <p class="font-mono tracking-label text-base-content/50 mb-2.5 text-xs uppercase">
                  Recent connections
                </p>
                <ul id="recent-connections" phx-update="stream" class="-mx-2 flex flex-col gap-0.5">
                  <li :for={{id, conn} <- @streams.recent_connections} id={id} class="list-none">
                    <ConnectComponents.connection_row conn={conn} pinned={false} />
                  </li>
                </ul>
              </div>

              <p class="font-mono tracking-snug text-base-content/35 mt-6 text-center text-xs">
                Uses BEAM distribution
              </p>
            </div>

            <.live_component
              :if={@mode == :ssh}
              module={VoyagerWeb.ConnectLive.SshConnect}
              id="ssh-connect"
              connected?={not is_nil(@connected_session)}
            />
          </div>
        </div>

        <.live_component
          :if={@show_distribution_settings?}
          module={VoyagerWeb.ConnectLive.DistributionSettings}
          id="distribution-settings-modal"
          connected?={not is_nil(@connected_session)}
        />
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("switch_mode", %{"mode" => "direct"}, socket) do
    socket
    |> assign(:mode, :direct)
    |> reset_connections()
    |> noreply()
  end

  def handle_event("switch_mode", %{"mode" => "ssh"}, socket) do
    {:noreply, assign(socket, :mode, :ssh)}
  end

  def handle_event("validate", %{"conn" => params}, socket) do
    changeset = ConnectionParams.changeset(params)
    {:noreply, assign(socket, :form, to_form(changeset, as: :conn))}
  end

  def handle_event("toggle_cookie", _, socket) do
    {:noreply, update(socket, :show_cookie, &(!&1))}
  end

  def handle_event("open_distribution_settings", _, socket) do
    {:noreply, assign(socket, :show_distribution_settings?, true)}
  end

  def handle_event("fill_recent", %{"id" => id}, socket) do
    case Integer.parse(id) do
      {int_id, ""} ->
        case ConnectionQueries.get(int_id) do
          nil ->
            {:noreply, reset_connections(socket)}

          conn ->
            changeset =
              ConnectionParams.changeset(%{
                "node_name" => conn.node_name,
                "cookie" => conn.cookie || "",
                "name_type" => conn.name_type
              })

            socket
            |> assign(:form, to_form(changeset, as: :conn))
            |> assign(:show_cookie, false)
            |> noreply()
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("connect", %{"conn" => params}, socket) do
    case ConnectionParams.changeset(params) |> Ecto.Changeset.apply_action(:insert) do
      {:ok, %ConnectionParams{} = p} -> do_connect(socket, params, p)
      {:error, changeset} -> {:noreply, assign(socket, :form, to_form(changeset, as: :conn))}
    end
  end

  def handle_event("pin", %{"id" => id}, socket) do
    ConnectionActions.pin(String.to_integer(id))
    {:noreply, reset_connections(socket)}
  end

  def handle_event("unpin", %{"id" => id}, socket) do
    ConnectionActions.unpin(String.to_integer(id))
    {:noreply, reset_connections(socket)}
  end

  def handle_event("delete_connection", %{"id" => id}, socket) do
    ConnectionActions.delete(String.to_integer(id))
    {:noreply, reset_connections(socket)}
  end

  @impl true
  def handle_info({:node_connected, _node}, socket) do
    {:noreply, assign(socket, :connected_session, NodeSession.current())}
  end

  def handle_info({event, _node}, socket) when event in [:node_disconnected, :nodedown] do
    {:noreply, assign(socket, :connected_session, nil)}
  end

  def handle_info({:distribution_settings, :saved}, socket) do
    socket
    |> put_flash(:info, "Distribution suffix saved")
    |> assign(:show_distribution_settings?, false)
    |> noreply()
  end

  def handle_info({:distribution_settings, :closed}, socket) do
    socket
    |> assign(:show_distribution_settings?, false)
    |> noreply()
  end

  def handle_info({:distribution_settings, :locked}, socket) do
    socket
    |> put_flash(:error, "Distribution suffix is controlled by application config")
    |> noreply()
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp do_connect(socket, params, %ConnectionParams{
         node_name: node_name,
         cookie: cookie,
         name_type: name_type,
         remember_cookie: remember_cookie
       }) do
    case NodeSession.connect(node_name, cookie, name_type: name_type) do
      :ok ->
        cookie_to_store = if remember_cookie, do: cookie, else: nil

        ConnectionActions.upsert_connected(node_name,
          cookie: cookie_to_store,
          name_type: name_type
        )

        {:noreply, redirect(socket, to: ~p"/node/#{node_name}")}

      {:error, reason} ->
        changeset =
          ConnectionParams.changeset(params)
          |> Ecto.Changeset.add_error(:node_name, connect_error(reason))
          |> Map.put(:action, :insert)

        {:noreply, assign(socket, :form, to_form(changeset, as: :conn))}
    end
  end

  defp reset_connections(socket) do
    connections = ConnectionQueries.all()
    {pinned, recent} = Enum.split_with(connections, & &1.pinned)

    socket
    |> stream(:pinned_connections, pinned, reset: true)
    |> stream(:recent_connections, recent, reset: true)
    |> assign(:has_pinned, pinned != [])
    |> assign(:has_recent, recent != [])
  end

  defp empty_form do
    ConnectionParams.changeset() |> to_form(as: :conn)
  end

  defp connect_error(:connection_failed),
    do: "Node unreachable - check the name is correct and the node is running"

  defp connect_error(:bad_cookie),
    do: "Authentication failed - the Erlang cookie does not match"

  defp connect_error(:name_type_mismatch),
    do: "Name type mismatch - try switching between --sname and --name"

  defp connect_error(:not_distributed), do: "Failed to start Erlang distribution"
  defp connect_error({:net_kernel, _}), do: "Failed to start Erlang distribution"
  defp connect_error({:net_kernel_stop, _}), do: "Failed to restart Erlang distribution"
  defp connect_error(_), do: "Could not connect to node"
end
