defmodule VoyagerWeb.ConnectLive.DirectConnect do
  use VoyagerWeb, :live_component

  alias VoyagerWeb.ConnectComponents
  alias Voyager.Actions.Connections, as: ConnectionActions
  alias Voyager.NodeSession
  alias Voyager.Queries.Connections, as: ConnectionQueries
  alias VoyagerWeb.ConnectLive.RecentConnections
  alias VoyagerWeb.ConnectLive.SecretVisibility
  alias VoyagerWeb.FormSchemas.ConnectionParams

  @impl true
  def update(
        %{connected?: new_status} = assigns,
        %{assigns: %{initialized: true, connected?: old_status}} = socket
      )
      when new_status != old_status do
    socket =
      socket
      |> assign(assigns)
      |> RecentConnections.reset()

    {:ok, socket}
  end

  def update(assigns, socket) when not is_map_key(socket.assigns, :initialized) do
    socket =
      socket
      |> assign(assigns)
      |> assign(:form, empty_form())
      |> SecretVisibility.init()
      |> RecentConnections.init(
        queries: ConnectionQueries,
        actions: ConnectionActions
      )
      |> assign(:initialized, true)

    {:ok, socket}
  end

  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :current_name_type,
        to_string(assigns.form[:name_type].value || "longnames")
      )

    ~H"""
    <div id={@id}>
      <.form
        for={@form}
        id="connect-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="connect"
        class={["flex flex-col gap-4", @connected? && "pointer-events-none opacity-40"]}
      >
        <ConnectComponents.form_field
          field={@form[:node_name]}
          label="Node name"
          placeholder={
            if @current_name_type == "longnames",
              do: "my_app@server.company.com",
              else: "my_app@my-machine"
          }
          disabled={@connected?}
        >
          <:trailing>
            <ConnectComponents.name_type_toggle
              name="conn[name_type]"
              value={@current_name_type}
              disabled={@connected?}
            />
          </:trailing>
        </ConnectComponents.form_field>

        <ConnectComponents.secret_field
          field={@form[:cookie]}
          label="Cookie"
          secret_key="cookie"
          shown={SecretVisibility.shown?(@secret_visibility, "cookie")}
          target={@myself}
          remember_name="conn[remember_cookie]"
          remember_checked={to_string(@form[:remember_cookie].value) == "true"}
          remember_label="Remember cookie"
          disabled={@connected?}
        />

        <ConnectComponents.connect_submit
          id="connect-btn"
          icon="icon-network"
          label="Connect"
          loading_label="Connecting…"
          disabled={@connected?}
        />
      </.form>

      <RecentConnections.render
        pinned_connections={@pinned_connections}
        recent_connections={@recent_connections}
        disabled={@connected?}
      >
        <:row :let={{conn, pinned}}>
          <.direct_connection_row conn={conn} pinned={pinned} target={@myself} disabled={@connected?} />
        </:row>
      </RecentConnections.render>

      <p class="font-mono tracking-snug text-base-content/35 mt-6 text-center text-xs">
        Uses BEAM distribution
      </p>
    </div>
    """
  end

  attr :conn, :map, required: true
  attr :pinned, :boolean, default: false
  attr :target, :any, required: true
  attr :disabled, :boolean, default: false

  defp direct_connection_row(assigns) do
    ~H"""
    <div class="flex w-full items-center gap-1">
      <button
        type="button"
        phx-target={@target}
        phx-click="fill_recent"
        phx-value-id={@conn.id}
        data-testid="fill-recent-btn"
        disabled={@disabled}
        class="font-mono text-base-content/60 flex min-w-0 flex-1 cursor-pointer items-center gap-2.5 rounded-md px-3 py-2 text-xs transition-colors hover:bg-base-200 hover:text-base-content"
      >
        <.icon name="icon-network" class="size-3.5 text-base-content/25 shrink-0" />
        <div class="flex min-w-0 items-center gap-1.5">
          <span class="ml-2 truncate">{@conn.node_name}</span>
          <ConnectComponents.saved_badge :if={@conn.cookie} label="cookie" title="Cookie saved" />
        </div>
        <span class="font-mono text-base-content/35 ml-auto shrink-0 text-xs">
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
  def handle_event("validate", %{"conn" => params}, socket) do
    changeset = ConnectionParams.changeset(params)
    {:noreply, assign(socket, :form, to_form(changeset, as: :conn))}
  end

  def handle_event("fill_recent", _params, %{assigns: %{connected?: true}} = socket) do
    {:noreply, socket}
  end

  def handle_event("fill_recent", %{"id" => id}, socket) do
    case Integer.parse(id) do
      {int_id, ""} ->
        case ConnectionQueries.get(int_id) do
          nil ->
            {:noreply, RecentConnections.reset(socket)}

          conn ->
            changeset =
              ConnectionParams.changeset(%{
                "node_name" => conn.node_name,
                "cookie" => conn.cookie || "",
                "name_type" => conn.name_type
              })

            socket
            |> assign(:form, to_form(changeset, as: :conn))
            |> SecretVisibility.reset()
            |> noreply()
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("fill_recent", _params, %{assigns: %{connected?: session}} = socket)
      when not is_nil(session) do
    {:noreply, socket}
  end

  def handle_event("connect", %{"conn" => params}, socket) do
    case ConnectionParams.changeset(params) |> Ecto.Changeset.apply_action(:insert) do
      {:ok, %ConnectionParams{} = p} -> do_connect(socket, params, p)
      {:error, changeset} -> {:noreply, assign(socket, :form, to_form(changeset, as: :conn))}
    end
  end

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
