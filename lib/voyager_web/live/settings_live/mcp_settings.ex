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
          <div>
            <h4 class="text-base-content text-sm font-semibold">Connect your AI</h4>
            <p class="text-base-content/70 mt-1 text-sm">
              Add Voyager to the AI clients installed on this machine, or run the command yourself.
            </p>
          </div>

          <ul id="mcp-clients" phx-update="stream" class="divide-base-200 flex flex-col divide-y">
            <li
              :for={{dom_id, client} <- @streams.clients}
              id={dom_id}
              class="flex flex-col gap-2 py-3"
            >
              <div class="flex items-center justify-between gap-3">
                <div class="flex items-center gap-2">
                  <span class="text-base-content text-sm font-medium">{client.name}</span>
                  <span
                    id={"#{dom_id}-status"}
                    class={["badge badge-sm", status_badge_class(client.status)]}
                  >
                    {status_label(client.status)}
                  </span>
                </div>
                <div class="flex items-center gap-2">
                  <button
                    :if={client.status in [:missing, :outdated]}
                    id={"#{dom_id}-install"}
                    type="button"
                    class={[
                      "btn btn-sm",
                      if(client.status == :outdated, do: "btn-warning", else: "btn-primary")
                    ]}
                    phx-click="install_client"
                    phx-value-id={client.id}
                    phx-target={@myself}
                  >
                    {if client.status == :outdated, do: "Update", else: "Add"}
                  </button>
                  <button
                    :if={client.status in [:configured, :outdated]}
                    id={"#{dom_id}-remove"}
                    type="button"
                    class="btn btn-sm btn-ghost"
                    phx-click="remove_client"
                    phx-value-id={client.id}
                    phx-target={@myself}
                  >
                    Remove
                  </button>
                </div>
              </div>
              <div
                :if={command = McpClients.cli_command(client.id, @status.url)}
                class="bg-base-200 flex items-center gap-2 rounded-md px-2 py-1"
              >
                <code
                  id={"#{dom_id}-command"}
                  class="font-mono text-base-content/80 flex-1 truncate text-xs"
                >
                  {command}
                </code>
                <.copy_button
                  id={"#{dom_id}-command-copy"}
                  target={"##{dom_id}-command"}
                  icon_only
                  label="Copy command"
                  size={:sm}
                />
              </div>
              <a
                :if={client.id == "cursor"}
                id={"#{dom_id}-deeplink"}
                href={McpClients.cursor_deeplink(@status.url)}
                class="link link-primary w-fit text-xs"
              >
                Open in Cursor
              </a>
            </li>
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

  def handle_event("install_client", %{"id" => id}, socket) do
    socket
    |> apply_client_change(McpClients.install(id, socket.assigns.status.url), "Voyager added")
    |> noreply()
  end

  def handle_event("remove_client", %{"id" => id}, socket) do
    socket
    |> apply_client_change(McpClients.remove(id), "Voyager removed")
    |> noreply()
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

  defp apply_client_change(socket, :ok, message) do
    socket
    |> push_flash(:info, message)
    |> stream_clients()
  end

  defp apply_client_change(socket, {:error, reason}, _message) do
    push_flash(socket, :error, "Failed to update client config: #{inspect(reason)}")
  end

  defp stream_clients(socket) do
    stream(socket, :clients, McpClients.statuses(socket.assigns.status.url), reset: true)
  end

  defp status_badge_class(:configured), do: "badge-success"
  defp status_badge_class(:outdated), do: "badge-warning"
  defp status_badge_class(_status), do: "badge-ghost"

  defp status_label(:configured), do: "Configured"
  defp status_label(:outdated), do: "Update available"
  defp status_label(:missing), do: "Not configured"
  defp status_label(:not_detected), do: "Not detected"

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
