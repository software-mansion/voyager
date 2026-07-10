defmodule VoyagerWeb.ConnectLive.DirectConnect do
  use VoyagerWeb, :live_component

  import VoyagerWeb.ConnectComponents,
    only: [
      form_field: 1,
      secret_field: 1,
      name_type_toggle: 1,
      connect_submit: 1,
      saved_badge: 1,
      row_actions: 1,
      relative_time: 1
    ]

  alias Voyager.Actions.Connections, as: ConnectionActions
  alias Voyager.NodeSession
  alias Voyager.Queries.Connections, as: ConnectionQueries
  alias VoyagerWeb.FormSchemas.ConnectionParams

  @impl true
  def update(%{id: id, connected?: connected?}, socket) do
    socket = assign(socket, id: id, connected?: connected?)

    socket =
      if socket.assigns[:initialized] do
        socket
      else
        socket
        |> assign(:form, empty_form())
        |> assign(:show_cookie, false)
        |> reset_connections()
        |> assign(:initialized, true)
      end

    ok(socket)
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
        <.form_field
          field={@form[:node_name]}
          label="Node name"
          placeholder="my_app@127.0.0.1"
          disabled={@connected?}
        >
          <:trailing>
            <.name_type_toggle
              name="conn[name_type]"
              value={@current_name_type}
              disabled={@connected?}
            />
          </:trailing>
        </.form_field>

        <.secret_field
          field={@form[:cookie]}
          label="Cookie"
          shown={@show_cookie}
          toggle_event="toggle_cookie"
          target={@myself}
          remember_name="conn[remember_cookie]"
          remember_checked={to_string(@form[:remember_cookie].value) == "true"}
          remember_label="Remember cookie"
          disabled={@connected?}
        />

        <.connect_submit
          id="connect-btn"
          icon="icon-network"
          label="Connect"
          loading_label="Connecting…"
          disabled={@connected?}
        />
      </.form>

      <div :if={@has_pinned} class="border-base-300 mt-7 border-t pt-5">
        <p class="font-mono tracking-label text-base-content/50 mb-2.5 text-xs uppercase">
          Favourites
        </p>
        <ul id="pinned-connections" phx-update="stream" class="-mx-2 flex flex-col gap-0.5">
          <li :for={{id, conn} <- @streams.pinned_connections} id={id} class="list-none">
            <.direct_connection_row conn={conn} pinned={true} target={@myself} />
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
            <.direct_connection_row conn={conn} pinned={false} target={@myself} />
          </li>
        </ul>
      </div>

      <p class="font-mono tracking-snug text-base-content/35 mt-6 text-center text-xs">
        Uses BEAM distribution
      </p>
    </div>
    """
  end

  attr :conn, :map, required: true
  attr :pinned, :boolean, default: false
  attr :target, :any, required: true

  defp direct_connection_row(assigns) do
    ~H"""
    <div class="flex w-full items-center gap-1">
      <button
        type="button"
        phx-target={@target}
        phx-click="fill_recent"
        phx-value-id={@conn.id}
        data-testid="fill-recent-btn"
        class="font-mono text-base-content/60 flex min-w-0 flex-1 cursor-pointer items-center gap-2.5 rounded-md px-3 py-2 text-xs transition-colors hover:bg-base-200 hover:text-base-content"
      >
        <.icon name="icon-network" class="size-3.5 text-base-content/25 shrink-0" />
        <div class="flex min-w-0 items-center gap-1.5">
          <span class="ml-2 truncate">{@conn.node_name}</span>
          <.saved_badge :if={@conn.cookie} label="cookie" title="Cookie saved" />
        </div>
        <span class="font-mono text-base-content/35 ml-auto shrink-0 text-xs">
          {relative_time(@conn.last_connected_at)}
        </span>
      </button>

      <.row_actions
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

  def handle_event("toggle_cookie", _, socket) do
    {:noreply, update(socket, :show_cookie, &(!&1))}
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
