defmodule VoyagerWeb.ConnectLive.SshConnect do
  @moduledoc """
  SSH-tunnel connection panel for `VoyagerWeb.ConnectLive`.
  """
  use VoyagerWeb, :live_component

  alias Voyager.Actions.SshConnections, as: SshConnectionActions
  alias Voyager.NodeSession
  alias Voyager.NodeSession.Connectors.Ssh, as: SshConnector
  alias Voyager.Queries.SshConnections, as: SshConnectionQueries
  alias VoyagerWeb.ConnectComponents
  alias VoyagerWeb.ConnectLive.RecentConnections
  alias VoyagerWeb.ConnectLive.SecretVisibility
  alias VoyagerWeb.FormSchemas.SshConnectionParams

  @impl true
  def update(
        %{connected?: new_status} = assigns,
        %{assigns: %{initialized: true, connected?: old_status}} = socket
      )
      when new_status != old_status do
    socket =
      socket
      |> assign_new(:id_prefix, fn -> "ssh-" end)
      |> assign(assigns)
      |> RecentConnections.reset()

    {:ok, socket}
  end

  def update(assigns, socket) when not is_map_key(socket.assigns, :initialized) do
    socket =
      socket
      |> assign_new(:id_prefix, fn -> "ssh-" end)
      |> assign(assigns)
      |> assign(:ssh_form, empty_ssh_form())
      |> SecretVisibility.init()
      |> assign(:show_ssh_advanced, false)
      |> assign(:ssh_connecting, false)
      |> assign(:ssh_last_applied, nil)
      |> RecentConnections.init(
        queries: SshConnectionQueries,
        actions: SshConnectionActions
      )
      |> assign(:initialized, true)

    {:ok, socket}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign_new(:id_prefix, fn -> "ssh-" end)
      |> assign(assigns)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:current_auth_method, to_string(assigns.ssh_form[:auth_method].value || "agent"))
      |> assign(:current_name_type, to_string(assigns.ssh_form[:name_type].value || "longnames"))

    ~H"""
    <div id={@id}>
      <.form
        for={@ssh_form}
        id={"#{@id_prefix}connect-form"}
        phx-target={@myself}
        phx-change="validate_ssh"
        phx-submit="connect_ssh"
        class={[
          "flex flex-col gap-4",
          (@connected? or @ssh_connecting) && "pointer-events-none opacity-40"
        ]}
      >
        <div class="flex gap-3">
          <div class="min-w-0 flex-1">
            <ConnectComponents.form_field
              field={@ssh_form[:ssh_user]}
              label="SSH User"
              placeholder="voyager"
              disabled={@connected? or @ssh_connecting}
            />
          </div>
          <div class="flex-2 min-w-0">
            <ConnectComponents.form_field
              field={@ssh_form[:ssh_host]}
              label="SSH Host"
              placeholder="10.0.0.5"
              disabled={@connected? or @ssh_connecting}
            />
          </div>
        </div>

        <ConnectComponents.form_field
          field={@ssh_form[:node_name]}
          label="Node Name"
          placeholder={
            if @current_name_type == "longnames",
              do: "my_app@server.company.com",
              else: "my_app@my-machine"
          }
          disabled={@connected? or @ssh_connecting}
        >
          <:trailing>
            <ConnectComponents.name_type_toggle
              name="ssh[name_type]"
              value={@current_name_type}
              disabled={@connected? or @ssh_connecting}
            />
          </:trailing>
        </ConnectComponents.form_field>

        <ConnectComponents.secret_field
          field={@ssh_form[:cookie]}
          label="Cookie"
          secret_key="cookie"
          shown={SecretVisibility.shown?(@secret_visibility, "cookie")}
          target={@myself}
          remember_name="ssh[remember_cookie]"
          remember_checked={to_string(@ssh_form[:remember_cookie].value) == "true"}
          remember_label="Remember cookie"
          disabled={@connected? or @ssh_connecting}
        />

        <div>
          <label class="font-mono tracking-label text-base-content/50 mb-1.5 block text-xs uppercase">
            Authentication
          </label>
          <ConnectComponents.segmented
            name="ssh[auth_method]"
            value={@current_auth_method}
            disabled={@connected? or @ssh_connecting}
            options={[
              %{value: "agent", label: "SSH Agent", id: "ssh-auth-agent"},
              %{value: "password", label: "Password", id: "ssh-auth-password"}
            ]}
          />
        </div>

        <ConnectComponents.secret_field
          :if={@current_auth_method == "password"}
          field={@ssh_form[:password]}
          label="SSH Password"
          secret_key="password"
          shown={SecretVisibility.shown?(@secret_visibility, "password")}
          target={@myself}
          remember_name="ssh[remember_password]"
          remember_checked={to_string(@ssh_form[:remember_password].value) == "true"}
          remember_label="Remember password"
          disabled={@connected? or @ssh_connecting}
        />

        <div>
          <button
            type="button"
            phx-target={@myself}
            phx-click="toggle_ssh_advanced"
            class="font-mono tracking-label text-base-content/40 cursor-pointer select-none text-xs uppercase transition-colors hover:text-base-content/70"
          >
            Advanced {if @show_ssh_advanced, do: "▾", else: "▸"}
          </button>

          <div class={[
            "border-base-300 mt-3 flex gap-3 rounded-lg border p-4",
            not @show_ssh_advanced && "hidden"
          ]}>
            <div class="flex-1">
              <ConnectComponents.form_field
                field={@ssh_form[:ssh_port]}
                label="SSH Port"
                type="number"
                min="1"
                max="65535"
                disabled={@connected? or @ssh_connecting}
              />
            </div>
            <div class="flex-1">
              <ConnectComponents.form_field
                field={@ssh_form[:epmd_port]}
                label="EPMD Port"
                type="number"
                min="1"
                max="65535"
                disabled={@connected? or @ssh_connecting}
              />
            </div>
          </div>
        </div>

        <ConnectComponents.connect_submit
          id={"#{@id_prefix}connect-btn"}
          icon="icon-network"
          label="Connect via SSH"
          loading_label="Connecting over SSH…"
          disabled={@connected? or @ssh_connecting}
        />
      </.form>

      <RecentConnections.render
        id_prefix={@id_prefix}
        pinned_connections={@pinned_connections}
        recent_connections={@recent_connections}
        disabled={@connected? or @ssh_connecting}
      >
        <:row :let={{conn, pinned}}>
          <.ssh_connection_row
            conn={conn}
            pinned={pinned}
            target={@myself}
            disabled={@connected? or @ssh_connecting}
          />
        </:row>
      </RecentConnections.render>

      <p class="font-mono tracking-snug text-base-content/35 mt-6 text-center text-xs">
        Connects via SSH tunnel
      </p>
    </div>
    """
  end

  attr :conn, :map, required: true, doc: "The SSH connection record from the database"
  attr :pinned, :boolean, default: false, doc: "Whether this connection is pinned"
  attr :target, :any, required: true, doc: "phx-target for the component's events"
  attr :disabled, :boolean, default: false

  defp ssh_connection_row(assigns) do
    ~H"""
    <div class="flex w-full items-center gap-1">
      <button
        type="button"
        phx-target={@target}
        phx-click="fill_ssh_recent"
        phx-value-id={@conn.id}
        data-testid="fill-ssh-recent-btn"
        disabled={@disabled}
        class="font-mono text-base-content/60 flex min-w-0 flex-1 cursor-pointer items-center gap-2.5 rounded-md px-3 py-2 text-xs transition-colors hover:bg-base-200 hover:text-base-content"
      >
        <.icon name="icon-network" class="size-3.5 text-base-content/25 shrink-0 self-center" />
        <div class="flex min-w-0 flex-1 flex-col gap-1">
          <span class="ml-2 truncate text-left">{@conn.node_name}</span>
          <div class="ml-2 flex flex-wrap items-center gap-1">
            <span class="font-mono text-base-content/30 border-base-300 rounded border px-1 text-xs">
              {@conn.ssh_user}@{@conn.ssh_host}
            </span>
            <ConnectComponents.saved_badge :if={@conn.cookie} label="cookie" title="Cookie saved" />
            <ConnectComponents.saved_badge :if={@conn.password} label="pass" title="Password saved" />
          </div>
        </div>
        <span class="font-mono text-base-content/35 shrink-0 self-center text-xs">
          {ConnectComponents.relative_time(@conn.last_connected_at)}
        </span>
      </button>

      <ConnectComponents.row_actions
        id={@conn.id}
        pinned={@pinned}
        pin_event="pin"
        unpin_event="unpin"
        delete_event="delete_connection"
        target={@target}
      />
    </div>
    """
  end

  @impl true
  def handle_event("validate_ssh", %{"ssh" => params}, socket) do
    changeset = SshConnectionParams.changeset(params)
    {:noreply, assign(socket, :ssh_form, to_form(changeset, as: :ssh))}
  end

  def handle_event("toggle_ssh_advanced", _, socket) do
    {:noreply, update(socket, :show_ssh_advanced, &(!&1))}
  end

  def handle_event("connect_ssh", _, %{assigns: %{ssh_connecting: true}} = socket) do
    {:noreply, socket}
  end

  def handle_event("connect_ssh", %{"ssh" => params}, socket) do
    changeset = SshConnectionParams.changeset(params)

    case Ecto.Changeset.apply_action(changeset, :insert) do
      {:ok, %SshConnectionParams{} = p} ->
        socket
        |> assign(:ssh_form, to_form(changeset, as: :ssh))
        |> start_ssh_connect(p)
        |> noreply()

      {:error, changeset} ->
        {:noreply, assign(socket, :ssh_form, to_form(changeset, as: :ssh))}
    end
  end

  def handle_event("fill_ssh_recent", _params, %{assigns: %{connected?: true}} = socket) do
    {:noreply, socket}
  end

  def handle_event("fill_ssh_recent", _params, %{assigns: %{ssh_connecting: true}} = socket) do
    {:noreply, socket}
  end

  def handle_event("fill_ssh_recent", %{"id" => id}, socket) do
    with_ssh_connection(socket, id, fn conn ->
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
      |> SecretVisibility.reset()
    end)
  end

  @impl true
  def handle_async(:ssh_connect, {:ok, :ok}, socket) do
    case NodeSession.current() do
      nil ->
        socket
        |> finish_connecting()
        |> assign(:ssh_form, error_form(socket.assigns.ssh_last_applied, :connection_lost))
        |> noreply()

      session ->
        persist_connection(socket.assigns.ssh_last_applied)

        socket
        |> assign(:ssh_connecting, false)
        |> redirect(to: ~p"/node/#{session.node_name}")
        |> noreply()
    end
  end

  def handle_async(:ssh_connect, {:ok, {:error, reason}}, socket) do
    socket
    |> finish_connecting()
    |> assign(:ssh_form, error_form(socket.assigns.ssh_last_applied, reason))
    |> noreply()
  end

  def handle_async(:ssh_connect, {:exit, _reason}, socket) do
    socket
    |> finish_connecting()
    |> assign(:ssh_form, error_form(socket.assigns.ssh_last_applied, :unexpected_exit))
    |> noreply()
  end

  defp start_ssh_connect(socket, %SshConnectionParams{} = p) do
    send(self(), {:ssh_connecting, true})

    socket
    |> assign(:ssh_connecting, true)
    |> assign(:ssh_last_applied, p)
    |> start_async(:ssh_connect, fn ->
      NodeSession.connect_via(SshConnector, p.node_name, p.cookie,
        ssh_user: p.ssh_user,
        ssh_host: p.ssh_host,
        auth: SshConnectionParams.to_auth(p),
        ssh_port: p.ssh_port,
        epmd_port: p.epmd_port,
        name_type: p.name_type
      )
    end)
  end

  defp finish_connecting(socket) do
    send(self(), {:ssh_connecting, false})
    assign(socket, :ssh_connecting, false)
  end

  defp persist_connection(%SshConnectionParams{} = p) do
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
  end

  defp with_ssh_connection(socket, id, fun) do
    case Integer.parse(id) do
      {int_id, ""} ->
        case SshConnectionQueries.get(int_id) do
          nil -> {:noreply, RecentConnections.reset(socket)}
          conn -> {:noreply, fun.(conn)}
        end

      _ ->
        {:noreply, socket}
    end
  end

  defp empty_ssh_form do
    SshConnectionParams.changeset() |> to_form(as: :ssh)
  end

  defp error_form(nil, _reason), do: empty_ssh_form()

  defp error_form(%SshConnectionParams{} = p, reason) do
    {field, msg} = ssh_connect_error(reason)

    p
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(field, msg)
    |> Map.put(:action, :insert)
    |> to_form(as: :ssh)
  end

  defp ssh_connect_error({:invalid_node_name, _}), do: {:node_name, "Use the name@host format"}

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

  defp ssh_connect_error(:nxdomain),
    do: {:ssh_host, "Host not found — check the SSH hostname"}

  defp ssh_connect_error(:ehostunreach),
    do: {:ssh_host, "Host unreachable — check the SSH hostname and your network"}

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

  defp ssh_connect_error(:connection_lost),
    do: {:node_name, "Connection was lost before it completed — please try again"}

  defp ssh_connect_error(:unexpected_exit),
    do: {:node_name, "Connection attempt failed unexpectedly"}

  defp ssh_connect_error(_), do: {:node_name, "Could not connect to remote node"}
end
