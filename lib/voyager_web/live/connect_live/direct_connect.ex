defmodule VoyagerWeb.ConnectLive.DirectConnect do
  use VoyagerWeb, :live_component

  alias Voyager.Actions.Connections, as: ConnectionActions
  alias Voyager.NodeSession
  alias Voyager.NodeSession.ConnectError
  alias Voyager.Queries.Connections, as: ConnectionQueries
  alias Voyager.Schemas.Connection
  alias VoyagerWeb.ConnectComponents
  alias VoyagerWeb.ConnectLive.RecentConnections
  alias VoyagerWeb.ConnectLive.SecretVisibility
  alias VoyagerWeb.FormSchemas.ConnectionParams

  @id_prefix "direct-"

  @impl true
  def mount(socket) do
    socket
    |> assign(:id_prefix, @id_prefix)
    |> ok()
  end

  @impl true
  def update(assigns, socket) when not is_map_key(socket.assigns, :initialized) do
    socket
    |> assign(:id, assigns.id)
    |> assign(:disabled?, assigns.disabled?)
    |> assign(:connecting?, assigns.connecting?)
    |> assign(:form, prefill_form(assigns.prefill))
    |> SecretVisibility.init()
    |> RecentConnections.init(
      queries: ConnectionQueries,
      actions: ConnectionActions
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
      |> assign(
        :current_name_type,
        to_string(assigns.form[:name_type].value || "longnames")
      )

    ~H"""
    <div id={@id}>
      <.form
        for={@form}
        id={"#{@id_prefix}connect-form"}
        phx-target={@myself}
        phx-change="validate"
        phx-submit="connect"
        class={["flex flex-col gap-4", @disabled? && "pointer-events-none"]}
      >
        <ConnectComponents.form_field
          field={@form[:node_name]}
          label="Node name"
          placeholder={
            if @current_name_type == "longnames",
              do: "my_app@server.company.com",
              else: "my_app@my-machine"
          }
          disabled={@disabled?}
        >
          <:trailing>
            <ConnectComponents.name_type_toggle
              name="conn[name_type]"
              value={@current_name_type}
              disabled={@disabled?}
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
          disabled={@disabled?}
        />

        <ConnectComponents.connect_submit
          id={"#{@id_prefix}connect-btn"}
          icon="icon-network"
          label="Connect"
          loading_label="Connecting…"
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
          <.direct_connection_row conn={conn} pinned={pinned} target={@myself} disabled={@disabled?} />
        </:row>
      </RecentConnections.render>

      <p class="font-mono tracking-snug text-base-content/70 mt-6 text-center text-xs">
        Nodes via distribution
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
        class="font-mono text-base-content/90 flex min-w-0 flex-1 cursor-pointer items-center gap-2.5 rounded-md px-3 py-2 text-xs transition-colors hover:bg-base-200 hover:text-base-content"
      >
        <.icon name="icon-network" class="size-3.5 text-base-content/60 shrink-0" />
        <div class="flex min-w-0 items-center gap-1.5">
          <span class="ml-2 truncate">{@conn.node_name}</span>
          <ConnectComponents.saved_badge :if={@conn.cookie} label="cookie" title="Cookie saved" />
        </div>
        <span class="font-mono text-base-content/70 ml-auto shrink-0 text-xs">
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

  def handle_event("fill_recent", _params, %{assigns: %{disabled?: true}} = socket) do
    {:noreply, socket}
  end

  def handle_event("fill_recent", %{"id" => id}, socket) do
    case Integer.parse(id) do
      {int_id, ""} ->
        case ConnectionQueries.get(int_id) do
          nil ->
            {:noreply, RecentConnections.reset(socket)}

          conn ->
            socket
            |> assign(:form, saved_form(conn))
            |> SecretVisibility.reset()
            |> noreply()
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("connect", %{"conn" => params}, socket) do
    changeset = ConnectionParams.changeset(params)

    case Ecto.Changeset.apply_action(changeset, :insert) do
      {:ok, %ConnectionParams{} = p} ->
        socket
        |> assign(:form, to_form(changeset, as: :conn))
        |> start_async(:connect, fn -> connect(p) end)
        |> noreply()

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :conn))}
    end
  end

  @impl true
  def handle_async(:connect, {:ok, {:error, reason}}, socket) do
    {:noreply, put_connect_error(socket, reason)}
  end

  def handle_async(:connect, {:exit, _reason}, socket) do
    {:noreply, put_connect_error(socket, :unexpected_exit)}
  end

  def handle_async(:connect, {:ok, :ok}, socket) do
    {:noreply, redirect(socket, to: ~p"/open")}
  end

  defp connect(%ConnectionParams{} = p) do
    with :ok <- NodeSession.connect(p.node_name, p.cookie, name_type: p.name_type) do
      ConnectionActions.upsert_connected(p.node_name,
        cookie: if(p.remember_cookie, do: p.cookie),
        name_type: p.name_type
      )

      :ok
    end
  end

  defp put_connect_error(socket, reason) do
    form =
      socket.assigns.form.params
      |> ConnectionParams.changeset()
      |> Ecto.Changeset.add_error(error_field(reason), ConnectError.message(reason))
      |> Map.put(:action, :insert)
      |> to_form(as: :conn)

    assign(socket, :form, form)
  end

  defp empty_form do
    ConnectionParams.changeset() |> to_form(as: :conn)
  end

  defp saved_form(conn) do
    %{"node_name" => conn.node_name, "cookie" => conn.cookie || "", "name_type" => conn.name_type}
    |> ConnectionParams.changeset()
    |> to_form(as: :conn)
  end

  defp prefill_form(%{"connection" => id}) when is_binary(id) do
    with {int_id, ""} <- Integer.parse(id),
         %Connection{} = conn <- ConnectionQueries.get(int_id) do
      saved_form(conn)
    else
      _ -> empty_form()
    end
  end

  defp prefill_form(%{} = params),
    do: params |> ConnectionParams.changeset() |> to_form(as: :conn)

  defp prefill_form(nil), do: empty_form()

  defp error_field(:bad_cookie), do: :cookie
  defp error_field(_reason), do: :node_name
end
