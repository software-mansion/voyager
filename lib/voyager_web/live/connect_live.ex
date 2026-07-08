defmodule VoyagerWeb.ConnectLive do
  use VoyagerWeb, :live_view

  alias Voyager.Actions.Connections, as: ConnectionActions
  alias Voyager.Actions.SshConnections, as: SshConnectionActions
  alias Voyager.NodeSession
  alias Voyager.Queries.Connections, as: ConnectionQueries
  alias Voyager.Queries.SshConnections, as: SshConnectionQueries
  alias VoyagerWeb.ConnectComponents
  alias VoyagerWeb.FormSchemas.ConnectionParams
  alias VoyagerWeb.FormSchemas.SshConnectionParams

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Voyager.PubSub, NodeSession.topic())
    end

    socket
    |> reset_connections()
    |> reset_ssh_connections()
    |> assign(:form, empty_form())
    |> assign(:show_distribution_settings?, false)
    |> assign(:show_cookie, false)
    |> assign(:connected_session, NodeSession.current())
    |> assign(:mode, :direct)
    |> assign(:ssh_form, empty_ssh_form())
    |> assign(:show_ssh_cookie, false)
    |> assign(:show_ssh_password, false)
    |> assign(:ssh_connecting, false)
    |> assign(:ssh_last_params, %{})
    |> assign(:ssh_last_applied, nil)
    |> assign(:show_ssh_advanced, false)
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

          <ConnectComponents.mode_toggle
            mode={@mode}
            disabled={not is_nil(@connected_session)}
          />

          <div :if={@mode == :direct}>
            <ConnectComponents.connect_form
              form={@form}
              show_cookie={@show_cookie}
              disabled={not is_nil(@connected_session)}
            />

            <%= if @has_pinned do %>
              <div class="border-base-300 mt-7 border-t pt-5">
                <p class="font-mono tracking-label text-base-content/50 mb-2.5 text-xs uppercase">
                  Favourites
                </p>
                <ul id="pinned-connections" phx-update="stream" class="-mx-2 flex flex-col gap-0.5">
                  <li :for={{id, conn} <- @streams.pinned_connections} id={id} class="list-none">
                    <ConnectComponents.connection_row conn={conn} pinned={true} />
                  </li>
                </ul>
              </div>
            <% end %>

            <%= if @has_recent do %>
              <div class={["border-base-300 border-t pt-5", if(@has_pinned, do: "mt-3", else: "mt-7")]}>
                <p class="font-mono tracking-label text-base-content/50 mb-2.5 text-xs uppercase">
                  Recent connections
                </p>
                <ul
                  id="recent-connections"
                  phx-update="stream"
                  class="-mx-2 flex flex-col gap-0.5"
                >
                  <li :for={{id, conn} <- @streams.recent_connections} id={id} class="list-none">
                    <ConnectComponents.connection_row conn={conn} pinned={false} />
                  </li>
                </ul>
              </div>
            <% end %>

            <p class="font-mono tracking-snug text-base-content/35 mt-6 text-center text-xs">
              Uses BEAM distribution
            </p>
          </div>

          <div :if={@mode == :ssh}>
            <ConnectComponents.ssh_connect_form
              form={@ssh_form}
              show_ssh_cookie={@show_ssh_cookie}
              show_ssh_password={@show_ssh_password}
              show_advanced={@show_ssh_advanced}
              connecting={@ssh_connecting}
              disabled={not is_nil(@connected_session)}
            />

            <%= if @has_pinned_ssh do %>
              <div class="border-base-300 mt-7 border-t pt-5">
                <p class="font-mono tracking-label text-base-content/50 mb-2.5 text-xs uppercase">
                  Favourites
                </p>
                <ul
                  id="pinned-ssh-connections"
                  phx-update="stream"
                  class="-mx-2 flex flex-col gap-0.5"
                >
                  <li
                    :for={{id, conn} <- @streams.pinned_ssh_connections}
                    id={id}
                    class="list-none"
                  >
                    <ConnectComponents.ssh_connection_row conn={conn} pinned={true} />
                  </li>
                </ul>
              </div>
            <% end %>

            <%= if @has_recent_ssh do %>
              <div class={[
                "border-base-300 border-t pt-5",
                if(@has_pinned_ssh, do: "mt-3", else: "mt-7")
              ]}>
                <p class="font-mono tracking-label text-base-content/50 mb-2.5 text-xs uppercase">
                  Recent connections
                </p>
                <ul
                  id="recent-ssh-connections"
                  phx-update="stream"
                  class="-mx-2 flex flex-col gap-0.5"
                >
                  <li
                    :for={{id, conn} <- @streams.recent_ssh_connections}
                    id={id}
                    class="list-none"
                  >
                    <ConnectComponents.ssh_connection_row conn={conn} pinned={false} />
                  </li>
                </ul>
              </div>
            <% end %>

            <p class="font-mono tracking-snug text-base-content/35 mt-6 text-center text-xs">
              Connects via SSH tunnel
            </p>
          </div>
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
    socket
    |> assign(:mode, :ssh)
    |> reset_ssh_connections()
    |> noreply()
  end

  def handle_event("validate", %{"conn" => params}, socket) do
    changeset = ConnectionParams.changeset(params)
    {:noreply, assign(socket, :form, to_form(changeset, as: :conn))}
  end

  def handle_event("validate_ssh", %{"ssh" => params}, socket) do
    changeset = SshConnectionParams.changeset(params)
    {:noreply, assign(socket, :ssh_form, to_form(changeset, as: :ssh))}
  end

  def handle_event("toggle_cookie", _, socket) do
    {:noreply, update(socket, :show_cookie, &(!&1))}
  end

  def handle_event("toggle_ssh_cookie", _, socket) do
    {:noreply, update(socket, :show_ssh_cookie, &(!&1))}
  end

  def handle_event("toggle_ssh_password", _, socket) do
    {:noreply, update(socket, :show_ssh_password, &(!&1))}
  end

  def handle_event("toggle_ssh_advanced", _, socket) do
    {:noreply, update(socket, :show_ssh_advanced, &(!&1))}
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

  def handle_event("connect_ssh", _, %{assigns: %{ssh_connecting: true}} = socket) do
    {:noreply, socket}
  end

  def handle_event("connect_ssh", %{"ssh" => params}, socket) do
    case SshConnectionParams.changeset(params) |> Ecto.Changeset.apply_action(:insert) do
      {:ok, %SshConnectionParams{} = p} ->
        socket
        |> assign(:ssh_form, to_form(SshConnectionParams.changeset(params), as: :ssh))
        |> assign(:ssh_connecting, true)
        |> assign(:ssh_last_params, params)
        |> assign(:ssh_last_applied, p)
        |> start_async(:ssh_connect, fn ->
          NodeSession.connect_ssh(p.node_name, p.cookie,
            ssh_user: p.ssh_user,
            ssh_host: p.ssh_host,
            auth: SshConnectionParams.to_auth(p),
            ssh_port: p.ssh_port,
            epmd_port: p.epmd_port,
            name_type: p.name_type
          )
        end)
        |> noreply()

      {:error, changeset} ->
        {:noreply, assign(socket, :ssh_form, to_form(changeset, as: :ssh))}
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

  def handle_event("fill_ssh_recent", %{"id" => id}, socket) do
    case Integer.parse(id) do
      {int_id, ""} ->
        case SshConnectionQueries.get(int_id) do
          nil ->
            {:noreply, reset_ssh_connections(socket)}

          conn ->
            params = %{
              "ssh_user" => conn.ssh_user,
              "ssh_host" => conn.ssh_host,
              "ssh_port" => to_string(conn.ssh_port),
              "node_name" => conn.node_name,
              "cookie" => conn.cookie || "",
              "name_type" => to_string(conn.name_type),
              "auth_method" => to_string(conn.auth_method),
              "password" => conn.password || "",
              "epmd_port" => to_string(conn.epmd_port)
            }

            socket
            |> assign(:ssh_form, to_form(SshConnectionParams.changeset(params), as: :ssh))
            |> assign(:show_ssh_cookie, false)
            |> assign(:show_ssh_password, false)
            |> noreply()
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("ssh_reconnect", %{"id" => id}, socket) do
    case Integer.parse(id) do
      {int_id, ""} ->
        case SshConnectionQueries.get(int_id) do
          nil ->
            {:noreply, reset_ssh_connections(socket)}

          conn ->
            p = %SshConnectionParams{
              ssh_user: conn.ssh_user,
              ssh_host: conn.ssh_host,
              ssh_port: conn.ssh_port,
              node_name: conn.node_name,
              cookie: conn.cookie || "",
              name_type: conn.name_type,
              auth_method: conn.auth_method,
              password: conn.password,
              epmd_port: conn.epmd_port,
              remember_cookie: not is_nil(conn.cookie),
              remember_password: not is_nil(conn.password)
            }

            socket
            |> assign(:ssh_connecting, true)
            |> assign(:ssh_last_applied, p)
            |> assign(:ssh_last_params, %{})
            |> start_async(:ssh_connect, fn ->
              NodeSession.connect_ssh(p.node_name, p.cookie,
                ssh_user: p.ssh_user,
                ssh_host: p.ssh_host,
                auth: SshConnectionParams.to_auth(p),
                ssh_port: p.ssh_port,
                epmd_port: p.epmd_port,
                name_type: p.name_type
              )
            end)
            |> noreply()
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("pin_ssh", %{"id" => id}, socket) do
    SshConnectionActions.pin(String.to_integer(id))
    {:noreply, reset_ssh_connections(socket)}
  end

  def handle_event("unpin_ssh", %{"id" => id}, socket) do
    SshConnectionActions.unpin(String.to_integer(id))
    {:noreply, reset_ssh_connections(socket)}
  end

  def handle_event("delete_ssh_connection", %{"id" => id}, socket) do
    SshConnectionActions.delete(String.to_integer(id))
    {:noreply, reset_ssh_connections(socket)}
  end

  @impl true
  def handle_async(:ssh_connect, {:ok, :ok}, socket) do
    session = NodeSession.current()
    p = socket.assigns.ssh_last_applied

    SshConnectionActions.upsert_connected(
      p.ssh_user,
      p.ssh_host,
      p.ssh_port,
      p.node_name,
      cookie: if(p.remember_cookie, do: p.cookie),
      name_type: p.name_type,
      auth_method: p.auth_method,
      password: if(p.remember_password and p.auth_method == :password, do: p.password),
      epmd_port: p.epmd_port
    )

    socket
    |> assign(:ssh_connecting, false)
    |> redirect(to: ~p"/node/#{session.node_name}")
    |> noreply()
  end

  def handle_async(:ssh_connect, {:ok, {:error, reason}}, socket) do
    {field, msg} = ssh_connect_error(reason)

    changeset =
      SshConnectionParams.changeset(socket.assigns.ssh_last_params)
      |> Ecto.Changeset.add_error(field, msg)
      |> Map.put(:action, :insert)

    socket
    |> assign(:ssh_connecting, false)
    |> assign(:ssh_form, to_form(changeset, as: :ssh))
    |> noreply()
  end

  def handle_async(:ssh_connect, {:exit, _reason}, socket) do
    socket
    |> assign(:ssh_connecting, false)
    |> put_flash(:error, "Connection attempt failed unexpectedly")
    |> noreply()
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

  defp reset_ssh_connections(socket) do
    conns = SshConnectionQueries.all()
    {pinned, recent} = Enum.split_with(conns, & &1.pinned)

    socket
    |> stream(:pinned_ssh_connections, pinned, reset: true)
    |> stream(:recent_ssh_connections, recent, reset: true)
    |> assign(:has_pinned_ssh, pinned != [])
    |> assign(:has_recent_ssh, recent != [])
  end

  defp empty_form do
    ConnectionParams.changeset() |> to_form(as: :conn)
  end

  defp empty_ssh_form do
    SshConnectionParams.changeset() |> to_form(as: :ssh)
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

  defp ssh_connect_error({:invalid_node_name, _}), do: {:node_name, "Use the name@host format"}
  defp ssh_connect_error({:invalid_node_format, _}), do: {:node_name, "Use the name@host format"}

  defp ssh_connect_error({:invalid_host, _}),
    do: {:ssh_host, "Invalid host — check the SSH hostname"}

  defp ssh_connect_error(reason) when is_list(reason),
    do:
      {:ssh_user,
       "SSH authentication failed — check your credentials or ensure the SSH agent is running"}

  defp ssh_connect_error(:etimedout),
    do: {:ssh_host, "Connection timed out — check the SSH host and port"}

  defp ssh_connect_error(:econnrefused),
    do: {:ssh_host, "Connection refused — check the SSH host and port"}

  defp ssh_connect_error({:node_not_found, _, _}),
    do:
      {:node_name,
       "Node not found on remote epmd — check the node name, or set a custom EPMD port in Advanced"}

  defp ssh_connect_error(:invalid_epmd_response),
    do: {:node_name, "Unexpected response from remote epmd — check the EPMD port in Advanced"}

  defp ssh_connect_error(:node_connect_failed),
    do: {:cookie, "Handshake failed — the Erlang cookie does not match"}

  defp ssh_connect_error(:not_distributed),
    do: {:node_name, "Failed to start local Erlang distribution"}

  defp ssh_connect_error({:net_kernel, _}),
    do: {:node_name, "Failed to start local Erlang distribution"}

  defp ssh_connect_error({:net_kernel_stop, _}),
    do: {:node_name, "Failed to restart local Erlang distribution"}

  defp ssh_connect_error(:invalid_name_type),
    do: {:node_name, "Invalid name type — try switching in Advanced settings"}

  defp ssh_connect_error(_), do: {:node_name, "Could not connect to remote node"}
end
