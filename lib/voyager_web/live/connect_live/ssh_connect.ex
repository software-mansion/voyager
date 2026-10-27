defmodule VoyagerWeb.ConnectLive.SshConnect do
  @moduledoc """
  SSH-tunnel connection panel for `VoyagerWeb.ConnectLive`.
  """
  use VoyagerWeb, :live_component

  alias Voyager.Actions.SshConnections, as: SshConnectionActions
  alias Voyager.NodeSession
  alias Voyager.NodeSession.ConnectError
  alias Voyager.NodeSession.Connectors.Ssh, as: SshConnector
  alias Voyager.Queries.SshConnections, as: SshConnectionQueries
  alias VoyagerWeb.ConnectComponents
  alias VoyagerWeb.ConnectLive.KeyAuth
  alias VoyagerWeb.ConnectLive.RecentConnections
  alias VoyagerWeb.ConnectLive.SecretVisibility
  alias VoyagerWeb.FormSchemas.SshConnectionParams

  @id_prefix "ssh-"
  @ssh_host_errors [
    :etimedout,
    :econnrefused,
    :nxdomain,
    :ehostunreach,
    :enetunreach,
    :enetdown,
    :ehostdown
  ]

  @impl true
  def mount(socket) do
    socket
    |> assign(:id_prefix, @id_prefix)
    |> assign(:connect_params, nil)
    |> assign(:host_key_prompt, nil)
    |> ok()
  end

  @impl true
  def update(assigns, socket) when not is_map_key(socket.assigns, :initialized) do
    socket
    |> assign(:id, assigns.id)
    |> assign(:disabled?, assigns.disabled?)
    |> assign(:connecting?, assigns.connecting?)
    |> assign(:ssh_form, empty_ssh_form())
    |> SecretVisibility.init()
    |> KeyAuth.init()
    |> assign(:show_ssh_advanced, false)
    |> RecentConnections.init(
      queries: SshConnectionQueries,
      actions: SshConnectionActions
    )
    |> assign(:initialized, true)
    |> ok()
  end

  def update(assigns, socket) do
    socket
    |> assign(:id, assigns.id)
    |> assign(:disabled?, assigns.disabled?)
    |> assign(:connecting?, assigns.connecting?)
    |> ok()
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
        class={["flex flex-col gap-4", @disabled? && "pointer-events-none"]}
      >
        <div class="flex gap-3">
          <div class="min-w-0 flex-1">
            <ConnectComponents.form_field
              field={@ssh_form[:ssh_user]}
              label="SSH User"
              placeholder="voyager"
              disabled={@disabled?}
            />
          </div>
          <div class="flex-2 min-w-0">
            <ConnectComponents.form_field
              field={@ssh_form[:ssh_host]}
              label="SSH Host"
              placeholder="10.0.0.5"
              disabled={@disabled?}
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
          disabled={@disabled?}
        >
          <:trailing>
            <ConnectComponents.name_type_toggle
              name="ssh[name_type]"
              value={@current_name_type}
              disabled={@disabled?}
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
          disabled={@disabled?}
        />

        <div>
          <label class="font-mono tracking-label text-base-content/70 mb-1.5 block text-xs uppercase">
            Authentication
          </label>
          <ConnectComponents.segmented
            name="ssh[auth_method]"
            value={@current_auth_method}
            disabled={@disabled?}
            options={[
              %{value: "agent", label: "SSH Agent", id: "ssh-auth-agent"},
              %{value: "password", label: "Password", id: "ssh-auth-password"},
              %{value: "key", label: "Key file", id: "ssh-auth-key"}
            ]}
          />
        </div>

        <div class={[@current_auth_method != "password" && "hidden"]}>
          <ConnectComponents.secret_field
            field={@ssh_form[:password]}
            label="SSH Password"
            secret_key="password"
            shown={SecretVisibility.shown?(@secret_visibility, "password")}
            target={@myself}
            remember_name="ssh[remember_password]"
            remember_checked={to_string(@ssh_form[:remember_password].value) == "true"}
            remember_label="Remember password"
            disabled={@disabled?}
          />
        </div>

        <div class={[@current_auth_method != "key" && "hidden"]}>
          <ConnectComponents.path_field
            field={@ssh_form[:key_path]}
            label="Identity file"
            placeholder="~/.ssh/id_ed25519"
            disabled={@disabled?}
          />
        </div>

        <div>
          <button
            type="button"
            phx-target={@myself}
            phx-click="toggle_ssh_advanced"
            class="font-mono tracking-label text-base-content/70 cursor-pointer select-none text-xs uppercase transition-colors hover:text-base-content/90"
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
                disabled={@disabled?}
              />
            </div>
            <div class="flex-1">
              <ConnectComponents.form_field
                field={@ssh_form[:epmd_port]}
                label="EPMD Port"
                type="number"
                min="1"
                max="65535"
                disabled={@disabled?}
              />
            </div>
          </div>
        </div>

        <ConnectComponents.connect_submit
          id={"#{@id_prefix}connect-btn"}
          icon="icon-network"
          label="Connect via SSH"
          loading_label="Connecting over SSH…"
          loading={@connecting?}
          disabled={@disabled?}
        />
      </.form>

      <RecentConnections.render
        id_prefix={@id_prefix}
        pinned_connections={@pinned_connections}
        recent_connections={@recent_connections}
        disabled={@disabled?}
      >
        <:row :let={{conn, pinned}}>
          <.ssh_connection_row
            conn={conn}
            pinned={pinned}
            target={@myself}
            disabled={@disabled?}
          />
        </:row>
      </RecentConnections.render>

      <p class="font-mono tracking-snug text-base-content/70 mt-6 text-center text-xs">
        Remote nodes via SSH
      </p>

      <ConnectComponents.passphrase_modal
        :if={@passphrase_form}
        id={"#{@id_prefix}passphrase-modal"}
        form={@passphrase_form}
        key_path={@ssh_form[:key_path].value}
        target={@myself}
        on_change="change_passphrase"
        on_submit="submit_passphrase"
        on_cancel="cancel_passphrase"
      />

      <ConnectComponents.host_key_modal
        :if={@host_key_prompt}
        id={"#{@id_prefix}host-key-modal"}
        host={"#{@connect_params.ssh_user}@#{host_with_port(@connect_params)}"}
        fingerprint={@host_key_prompt}
        password_auth={@connect_params.auth_method == :password}
        target={@myself}
        on_accept="accept_host_key"
        on_reject="reject_host_key"
      />
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
        class="font-mono text-base-content/90 flex min-w-0 flex-1 cursor-pointer items-center gap-2.5 rounded-md px-3 py-2 text-xs transition-colors hover:bg-base-200 hover:text-base-content"
      >
        <.icon name="icon-network" class="size-3.5 text-base-content/60 shrink-0 self-center" />
        <div class="flex min-w-0 flex-1 flex-col gap-1">
          <span class="ml-2 truncate text-left">{@conn.node_name}</span>
          <div class="ml-2 flex flex-wrap items-center gap-1">
            <span class="font-mono text-base-content/70 border-base-400/50 rounded border px-1 text-xs">
              {@conn.ssh_user}@{@conn.ssh_host}
            </span>
            <ConnectComponents.saved_badge :if={@conn.cookie} label="cookie" title="Cookie saved" />
            <ConnectComponents.saved_badge :if={@conn.password} label="pass" title="Password saved" />
            <ConnectComponents.saved_badge
              :if={@conn.key_path}
              label="key path"
              title="Key path saved"
            />
          </div>
        </div>
        <span class="font-mono text-base-content/70 shrink-0 self-center text-xs">
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
    {:noreply, assign(socket, :ssh_form, KeyAuth.checked_form(changeset))}
  end

  def handle_event("toggle_ssh_advanced", _, socket) do
    {:noreply, update(socket, :show_ssh_advanced, &(!&1))}
  end

  def handle_event("connect_ssh", %{"ssh" => params}, socket) do
    changeset = params |> SshConnectionParams.changeset() |> KeyAuth.add_error()

    case Ecto.Changeset.apply_action(changeset, :insert) do
      {:ok, %SshConnectionParams{} = p} ->
        socket
        |> assign(:ssh_form, to_form(changeset, as: :ssh))
        |> KeyAuth.connect(p, &start_connect/2)
        |> noreply()

      {:error, changeset} ->
        {:noreply, assign(socket, :ssh_form, to_form(changeset, as: :ssh))}
    end
  end

  def handle_event(
        "submit_passphrase",
        %{"passphrase" => %{"passphrase" => passphrase}},
        %{assigns: %{passphrase_form: %Phoenix.HTML.Form{}}} = socket
      ) do
    case Ecto.Changeset.apply_action(socket.assigns.ssh_form.source, :insert) do
      {:ok, %SshConnectionParams{} = p} ->
        socket
        |> KeyAuth.connect(%{p | passphrase: passphrase}, &start_connect/2)
        |> noreply()

      {:error, _changeset} ->
        {:noreply, assign(socket, :passphrase_form, nil)}
    end
  end

  def handle_event("submit_passphrase", _params, socket), do: {:noreply, socket}

  def handle_event("accept_host_key", _params, %{assigns: %{host_key_prompt: fp}} = socket)
      when is_binary(fp) do
    socket
    |> assign(:host_key_prompt, nil)
    |> start_connect(socket.assigns.connect_params, fp)
    |> noreply()
  end

  def handle_event("accept_host_key", _params, socket), do: {:noreply, socket}

  def handle_event("reject_host_key", _params, socket) do
    {:noreply, assign(socket, :host_key_prompt, nil)}
  end

  def handle_event("fill_ssh_recent", _params, %{assigns: %{disabled?: true}} = socket) do
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
        "key_path" => conn.key_path || "",
        "epmd_port" => to_string(conn.epmd_port)
      }

      socket
      |> assign(:ssh_form, KeyAuth.checked_form(SshConnectionParams.changeset(params)))
      |> SecretVisibility.reset()
    end)
  end

  @impl true
  def handle_async(:ssh_connect, {:ok, {:error, {:unknown_host_key, fp}}}, socket) do
    {:noreply, assign(socket, :host_key_prompt, fp)}
  end

  def handle_async(:ssh_connect, {:ok, {:error, reason}}, socket) do
    {:noreply, put_connect_error(socket, reason)}
  end

  def handle_async(:ssh_connect, {:exit, _reason}, socket) do
    {:noreply, put_connect_error(socket, :unexpected_exit)}
  end

  def handle_async(:ssh_connect, {:ok, :ok}, socket) do
    {:noreply, redirect(socket, to: ~p"/open")}
  end

  defp start_connect(socket, %SshConnectionParams{} = p, host_key \\ nil) do
    socket
    |> assign(:connect_params, p)
    |> start_async(:ssh_connect, fn -> connect(p, host_key) end)
  end

  defp connect(%SshConnectionParams{} = p, host_key) do
    opts = [
      ssh_user: p.ssh_user,
      ssh_host: p.ssh_host,
      auth: SshConnectionParams.to_auth(p),
      ssh_port: p.ssh_port,
      epmd_port: p.epmd_port,
      name_type: p.name_type,
      host_key: host_key
    ]

    with :ok <- NodeSession.connect_via(SshConnector, p.node_name, p.cookie, opts) do
      persist_connection(p)
      :ok
    end
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
      key_path: if(p.auth_method == :key, do: p.key_path),
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

  defp put_connect_error(socket, reason) do
    form =
      socket.assigns.ssh_form.params
      |> SshConnectionParams.changeset()
      |> Ecto.Changeset.add_error(error_field(reason), ConnectError.message(reason))
      |> Map.put(:action, :insert)
      |> to_form(as: :ssh)

    assign(socket, :ssh_form, form)
  end

  defp host_with_port(%SshConnectionParams{ssh_host: host, ssh_port: port}) do
    if String.contains?(host, ":"), do: "[#{host}]:#{port}", else: "#{host}:#{port}"
  end

  defp error_field({:invalid_host, _}), do: :ssh_host

  defp error_field({reason, _file})
       when reason in [:host_key_mismatch, :host_key_revoked, :known_hosts_unreadable],
       do: :ssh_host

  defp error_field(reason) when is_list(reason), do: :ssh_user

  defp error_field(reason) when reason in @ssh_host_errors, do: :ssh_host

  defp error_field(:node_connect_failed), do: :cookie
  defp error_field(_reason), do: :node_name
end
