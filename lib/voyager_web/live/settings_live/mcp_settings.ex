defmodule VoyagerWeb.SettingsLive.McpSettings do
  @moduledoc false
  use VoyagerWeb, :live_component

  alias Voyager.MCP
  alias Voyager.Services.McpClients
  alias Voyager.Settings
  alias VoyagerWeb.FormSchemas.McpPort

  require Logger

  @default_port 4040

  @impl true
  def mount(socket) do
    socket
    |> assign(:port_locked?, Settings.locked?(:mcp_port))
    |> assign(:enabled_locked?, Settings.locked?(:mcp_enabled))
    |> assign(:toggle_revision, 0)
    |> assign(:form, mcp_port_form())
    |> stream_configure(:clients, dom_id: &"mcp-client-#{&1.id}")
    |> assign(:other_connections, [])
    |> ok()
  end

  @impl true
  def update(assigns, socket) do
    socket
    |> assign(assigns)
    |> stream_clients()
    |> ok()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="card bg-base-100 border-base-200 border shadow-sm">
      <div class="card-body gap-4 p-5">
        <div class="flex items-start justify-between gap-4">
          <div>
            <h3 class="text-base-content text-sm font-semibold">MCP Server</h3>
            <p class="text-base-content/70 mt-1 text-sm">
              Exposes node introspection tools to MCP clients over HTTP.
            </p>
          </div>
          <input
            id="mcp-toggle"
            type="checkbox"
            class="toggle toggle-primary mt-1"
            aria-label="Toggle MCP server"
            checked={@status.alive?}
            disabled={@enabled_locked?}
            data-toggle-revision={@toggle_revision}
            phx-click="toggle"
            phx-target={@myself}
          />
        </div>

        <div :if={@enabled_locked? or @port_locked?} id="mcp-locked" class="alert alert-info text-sm">
          <.icon name="icon-info" class="text-info size-4" />
          <span>
            {locked_alert_text(@enabled_locked?, @port_locked?)}
          </span>
        </div>

        <div class="text-base-content/70 font-mono flex items-center gap-1.5 text-xs">
          <span class="relative flex h-1.5 w-1.5">
            <span
              :if={@status.alive?}
              class="bg-success absolute inline-flex h-full w-full animate-ping rounded-full opacity-75"
            ></span>
            <span class={[
              "relative inline-flex h-1.5 w-1.5 rounded-full",
              if(@status.alive?, do: "bg-success", else: "bg-error")
            ]}></span>
          </span>
          {if @status.alive?, do: "Running at #{@status.url}", else: "Stopped"}
        </div>

        <.form
          for={@form}
          id="mcp-port-form"
          phx-change="validate_port"
          phx-submit="save_port"
          phx-target={@myself}
          class="flex flex-col gap-4"
        >
          <div>
            <div class="mb-1.5 flex items-center gap-2">
              <label
                class="font-mono tracking-label text-base-content/70 flex items-center gap-0.5 text-xs font-semibold uppercase"
                for={@form[:port].id}
              >
                Port
              </label>
            </div>
            <.input
              field={@form[:port]}
              type="number"
              placeholder="4040"
              disabled={@port_locked?}
              class="font-mono text-sm"
            />
          </div>

          <div class="card-actions justify-end">
            <button type="submit" class="btn btn-primary" disabled={@port_locked?}>
              Save port
            </button>
          </div>
        </.form>

        <div id="mcp-clients-section" class="border-base-200 flex flex-col gap-3 border-t pt-4">
          <h4 class="text-base-content text-sm font-semibold">Connect your AI</h4>

          <ul id="mcp-clients" phx-update="stream" class="flex flex-col gap-2">
            <.client_card
              :for={{dom_id, client} <- @streams.clients}
              id={dom_id}
              icon={client_icon(client.id)}
              name={client.name}
              subtitle={client.subtitle}
              connection={client.connection}
              added?={client.added?}
            >
              <div
                :if={not client.installed? and not client.added?}
                id={"#{dom_id}-missing"}
                role="status"
                class="alert alert-info gap-2 px-3 py-2 text-xs"
              >
                <.icon name="icon-info" class="text-info size-4 shrink-0" />
                <span>
                  {client.name} wasn't found on this machine. Install it, then {if(client.link,
                    do: "click Add",
                    else: "run the command below"
                  )}.
                </span>
              </div>
              <:action :if={client.link}>
                <a
                  id={"#{dom_id}-add"}
                  href={client.link}
                  class={[
                    "btn btn-sm",
                    if(client.added? or client.connection, do: "btn-ghost", else: "btn-primary")
                  ]}
                >
                  {if client.added? or client.connection, do: "Reinstall", else: "Add"}
                </a>
              </:action>
              <div
                :if={client.command}
                class="bg-base-200/60 flex items-center gap-2 rounded-md py-1 pr-1 pl-2.5"
              >
                <code
                  id={"#{dom_id}-command"}
                  title={client.command}
                  class="font-mono text-base-content/80 min-w-0 flex-1 truncate text-xs"
                >{client.command}</code>
                <.copy_button
                  id={"#{dom_id}-copy"}
                  target={"##{dom_id}-command"}
                  icon_only
                  label="Copy command"
                  size={:sm}
                />
              </div>
            </.client_card>
          </ul>

          <ul class="flex flex-col gap-2">
            <.client_card
              id="mcp-client-other"
              icon="icon-brain"
              name="Other agent"
              subtitle="Paste the setup prompt into any agent"
            >
              <:action>
                <span id="mcp-setup-prompt" class="hidden">{McpClients.setup_prompt(@status.url)}</span>
                <.copy_button
                  id="mcp-setup-prompt-copy"
                  target="#mcp-setup-prompt"
                  label="Copy setup prompt"
                />
              </:action>
              <div :if={@other_connections != []} class="flex flex-wrap gap-x-4 gap-y-1">
                <.connected_badge
                  :for={connection <- @other_connections}
                  id={"mcp-client-other-#{:erlang.phash2(connection.name)}"}
                  connection={connection}
                  label={connection.name}
                />
              </div>
            </.client_card>
          </ul>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("toggle", _params, socket) do
    case MCP.toggle() do
      {:ok, _state} ->
        {:noreply, socket}

      {:error, reason} ->
        # The browser already flipped the checkbox, and `@status` is unchanged,
        # so without a diff the component is never patched and the toggle stays
        # out of sync. Bumping the revision forces a patch, which makes
        # LiveView re-apply the server-rendered `checked` state.
        socket
        |> push_flash(:error, "Failed to toggle MCP server: #{inspect(reason)}")
        |> assign(:toggle_revision, socket.assigns.toggle_revision + 1)
        |> noreply()
    end
  end

  def handle_event("validate_port", %{"mcp_port" => params}, socket) do
    changeset = McpPort.changeset(params)

    socket
    |> assign(:form, to_form(changeset, as: :mcp_port))
    |> noreply()
  end

  def handle_event("save_port", %{"mcp_port" => params}, socket) do
    changeset = McpPort.changeset(params)

    with {:ok, %McpPort{port: port}} <- Ecto.Changeset.apply_action(changeset, :insert),
         :ok <- MCP.set_port(port) do
      socket
      |> push_flash(:info, "MCP port updated")
      |> noreply()
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        socket
        |> assign(:form, to_form(changeset, as: :mcp_port))
        |> noreply()

      {:error, :locked} ->
        socket
        |> push_flash(:error, "MCP port is controlled by application config")
        |> assign(:port_locked?, true)
        |> assign(:form, mcp_port_form())
        |> noreply()

      {:error, :port_in_use} ->
        socket
        |> push_flash(:error, "That port is already in use")
        |> assign(:form, mcp_port_form())
        |> noreply()

      {:error, reason} ->
        Logger.error("Failed to set MCP port: #{inspect(reason)}")

        socket
        |> push_flash(:error, "Failed to update MCP port: #{inspect(reason)}")
        |> assign(:form, mcp_port_form())
        |> noreply()
    end
  end

  defp stream_clients(socket) do
    connections = Map.get(socket.assigns, :connections, [])
    by_id = Enum.group_by(connections, &McpClients.match(&1.name))

    clients =
      Enum.map(McpClients.all(socket.assigns.status.url), fn client ->
        Map.put(client, :connection, latest(Map.get(by_id, client.id, [])))
      end)

    socket
    |> assign(:other_connections, Enum.filter(connections, &is_nil(McpClients.match(&1.name))))
    |> stream(:clients, clients, reset: true)
  end

  defp latest(connections), do: Enum.max_by(connections, & &1.last_seen, DateTime, fn -> nil end)

  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :name, :string, required: true
  attr :subtitle, :string, required: true
  attr :connection, :map, default: nil
  attr :added?, :boolean, default: false
  slot :action
  slot :inner_block

  defp client_card(assigns) do
    ~H"""
    <li
      id={@id}
      class="rounded-box border-base-200 flex flex-col gap-3 border p-3 transition-colors hover:border-base-300 hover:bg-base-200/30"
    >
      <div class="flex items-center gap-3">
        <span class="bg-base-200 text-base-content size-9 flex shrink-0 items-center justify-center rounded-lg">
          <.icon name={@icon} class="size-5" />
        </span>
        <div class="min-w-0 flex-1">
          <div class="flex flex-wrap items-center gap-x-2">
            <span class="text-base-content text-sm font-medium">{@name}</span>
            <.connected_badge :if={@connection} id={"#{@id}-connected"} connection={@connection} />
            <span
              :if={@added? and is_nil(@connection)}
              id={"#{@id}-added"}
              class="text-base-content/60 flex items-center gap-1 text-xs"
            >
              <.icon name="icon-check" class="text-success size-3.5" /> Added
            </span>
          </div>
          <p class="text-base-content/60 truncate text-xs">{@subtitle}</p>
        </div>
        {render_slot(@action)}
      </div>
      {render_slot(@inner_block)}
    </li>
    """
  end

  attr :id, :string, required: true
  attr :connection, :map, required: true
  attr :label, :string, default: "Connected"

  defp connected_badge(assigns) do
    ~H"""
    <span id={@id} class="text-base-content/60 flex items-center gap-1.5 text-xs">
      <span class="relative flex h-1.5 w-1.5">
        <span class="bg-success absolute inline-flex h-full w-full animate-ping rounded-full opacity-75"></span>
        <span class="bg-success relative inline-flex h-1.5 w-1.5 rounded-full"></span>
      </span>
      {Enum.join(
        Enum.reject(
          [@label, @connection.version && "v#{@connection.version}", ago(@connection.last_seen)],
          &is_nil/1
        ),
        " · "
      )}
    </span>
    """
  end

  defp client_icon(:claude_code), do: "icon-brand-claude"
  defp client_icon(:codex), do: "icon-brand-openai"
  defp client_icon(:gemini), do: "icon-brand-gemini"
  defp client_icon(:cursor), do: "icon-brand-cursor"

  defp ago(datetime) do
    case DateTime.diff(DateTime.utc_now(), datetime) do
      seconds when seconds < 60 -> "just now"
      seconds when seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds when seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      seconds -> "#{div(seconds, 86_400)}d ago"
    end
  end

  defp mcp_port_form do
    %{"port" => Settings.get(:mcp_port, @default_port)}
    |> McpPort.changeset()
    |> to_form(as: :mcp_port)
  end

  defp locked_alert_text(true, true),
    do:
      "The MCP server and its port are controlled by application config, so changes are disabled."

  defp locked_alert_text(true, false),
    do:
      "The MCP server is controlled by application config, so it cannot be turned on or off here."

  defp locked_alert_text(false, true),
    do: "The MCP port is controlled by application config, so it cannot be changed here."
end
