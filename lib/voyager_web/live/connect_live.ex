defmodule VoyagerWeb.ConnectLive do
  use VoyagerWeb, :live_view

  alias Voyager.Connect.Params
  alias Voyager.{Connections, NodeSession}
  alias VoyagerWeb.ConnectComponents

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> reset_connections()
     |> assign(:form, empty_form())
     |> assign(:show_cookie, false)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="bg-base-200 flex h-full items-center justify-center p-4">
      <div class="card bg-base-100 max-w-[480px] w-full shadow-xl">
        <div class="card-body gap-0 p-10">
          <div class="mb-7 flex items-center gap-3">
            <.logo />
            <div class="text-[17px] text-base-content font-semibold tracking-tight">Voyager</div>
          </div>
          <div class="mb-6">
            <h1 class="text-[22px] text-base-content font-semibold tracking-tight">
              Connect to a node
            </h1>
            <p class="text-[13.5px] text-base-content/60 mt-1">
              Enter the node name and Erlang cookie to inspect a local or remote BEAM.
            </p>
          </div>

          <ConnectComponents.connect_form form={@form} show_cookie={@show_cookie} />

          <%= if @has_pinned do %>
            <div class="border-base-300 mt-7 border-t pt-5">
              <p class="font-mono text-[10.5px] tracking-[0.08em] text-base-content/50 mb-2.5 uppercase">
                Favourites
              </p>
              <ul id="pinned-connections" phx-update="stream" class="menu -mx-2 gap-0.5 p-0">
                <li :for={{id, conn} <- @streams.pinned_connections} id={id}>
                  <ConnectComponents.connection_row conn={conn} pinned={true} />
                </li>
              </ul>
            </div>
          <% end %>

          <%= if @has_recent do %>
            <div class={["border-base-300 border-t pt-5", if(@has_pinned, do: "mt-3", else: "mt-7")]}>
              <p class="font-mono text-[10.5px] tracking-[0.08em] text-base-content/50 mb-2.5 uppercase">
                Recent connections
              </p>
              <ul id="recent-connections" phx-update="stream" class="menu -mx-2 gap-0.5 p-0">
                <li :for={{id, conn} <- @streams.recent_connections} id={id}>
                  <ConnectComponents.connection_row conn={conn} pinned={false} />
                </li>
              </ul>
            </div>
          <% end %>

          <p class="font-mono text-[10.5px] tracking-[0.02em] text-base-content/35 mt-6 text-center">
            No code changes required · uses Erlang distribution
          </p>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("validate", %{"conn" => params}, socket) do
    changeset = Params.changeset(params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, :form, to_form(changeset, as: :conn))}
  end

  def handle_event("toggle_cookie", _, socket) do
    {:noreply, update(socket, :show_cookie, &(!&1))}
  end

  def handle_event("fill_recent", %{"id" => id}, socket) do
    case Integer.parse(id) do
      {int_id, ""} ->
        case Connections.get(int_id) do
          nil ->
            {:noreply, reset_connections(socket)}

          conn ->
            current_name_type = socket.assigns.form[:name_type].value || :shortnames

            changeset =
              Params.changeset(%{
                "node_name" => conn.node_name,
                "cookie" => conn.cookie || "",
                "name_type" => current_name_type
              })

            {:noreply,
             socket
             |> assign(:form, to_form(changeset, as: :conn))
             |> assign(:show_cookie, not is_nil(conn.cookie))}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("connect", %{"conn" => params}, socket) do
    case Params.changeset(params) |> Ecto.Changeset.apply_action(:insert) do
      {:ok, %Params{} = p} -> do_connect(socket, params, p)
      {:error, changeset} -> {:noreply, assign(socket, :form, to_form(changeset, as: :conn))}
    end
  end

  def handle_event("pin", %{"id" => id}, socket) do
    Connections.pin(String.to_integer(id))
    {:noreply, reset_connections(socket)}
  end

  def handle_event("unpin", %{"id" => id}, socket) do
    Connections.unpin(String.to_integer(id))
    {:noreply, reset_connections(socket)}
  end

  def handle_event("delete_connection", %{"id" => id}, socket) do
    Connections.delete(String.to_integer(id))
    {:noreply, reset_connections(socket)}
  end

  defp do_connect(socket, params, %Params{
         node_name: node_name,
         cookie: cookie,
         name_type: name_type,
         remember_cookie: remember_cookie
       }) do
    case NodeSession.connect(node_name, cookie, name_type: name_type) do
      :ok ->
        cookie_to_store = if remember_cookie, do: cookie, else: nil
        Connections.upsert_connected(node_name, cookie: cookie_to_store)
        {:noreply, push_navigate(socket, to: ~p"/node/#{node_name}")}

      {:error, reason} ->
        changeset =
          Params.changeset(params)
          |> Ecto.Changeset.add_error(:node_name, connect_error(reason))
          |> Map.put(:action, :insert)

        {:noreply, assign(socket, :form, to_form(changeset, as: :conn))}
    end
  end

  defp reset_connections(socket) do
    connections = Connections.list_connections()
    {pinned, recent} = Enum.split_with(connections, & &1.pinned)

    socket
    |> stream(:pinned_connections, pinned, reset: true)
    |> stream(:recent_connections, recent, reset: true)
    |> assign(:has_pinned, pinned != [])
    |> assign(:has_recent, recent != [])
  end

  defp empty_form do
    Params.changeset() |> to_form(as: :conn)
  end

  defp connect_error(:connection_failed),
    do: "Connection failed - check the node name and that the node is running"

  defp connect_error(:not_distributed), do: "Failed to start Erlang distribution"
  defp connect_error({:net_kernel, _}), do: "Failed to start Erlang distribution"
  defp connect_error(_), do: "Could not connect to node"
end
