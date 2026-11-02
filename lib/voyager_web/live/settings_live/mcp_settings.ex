defmodule VoyagerWeb.SettingsLive.McpSettings do
  @moduledoc false
  use VoyagerWeb, :live_component

  alias Voyager.MCP
  alias Voyager.Services.McpClients
  alias Voyager.Settings
  alias VoyagerWeb.FormSchemas.McpPort
  alias VoyagerWeb.McpComponents

  require Logger

  @default_port 4040

  @impl true
  def mount(socket) do
    socket
    |> assign(:port_locked?, Settings.locked?(:mcp_port))
    |> assign(:enabled_locked?, Settings.locked?(:mcp_enabled))
    |> assign(:toggle_revision, 0)
    |> assign(:form, mcp_port_form())
    |> stream_configure(:agents, dom_id: &"mcp-agent-#{McpComponents.agent_key(&1)}")
    |> ok()
  end

  @impl true
  def update(assigns, socket) do
    socket
    |> assign(assigns)
    |> stream(:agents, assigns.agents.agents, reset: true)
    |> ok()
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :running?, assigns.agents.state != :off)

    ~H"""
    <div
      id={@id}
      class="card bg-base-100 border-base-200 scroll-mt-6 border shadow-sm target:outline-primary target:outline-2 target:outline-offset-4"
    >
      <div class="card-body gap-5 p-5">
        <div class="flex items-start justify-between gap-4">
          <div>
            <h3 class="text-base-content text-sm font-semibold">MCP server</h3>
            <p class="text-base-content/70 mt-1 text-sm">
              Let coding agents inspect the node you are connected to, through Voyager's MCP server.
            </p>
          </div>
          <input
            id="mcp-toggle"
            type="checkbox"
            class="toggle toggle-primary mt-1"
            aria-label="Toggle MCP server"
            checked={@running?}
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

        <div class="text-base-content/70 font-mono -mt-2 flex items-center gap-1.5 text-xs">
          <span class="size-1.5 relative flex">
            <span
              :if={@running?}
              class="bg-success absolute inline-flex h-full w-full animate-ping rounded-full opacity-75"
            ></span>
            <span class={[
              "size-1.5 relative inline-flex rounded-full",
              if(@running?, do: "bg-success", else: "bg-error")
            ]}></span>
          </span>
          <span id="mcp-url-status">
            {if @running?, do: "Running at #{@agents.url}", else: "Stopped"}
          </span>
          <McpComponents.copy_text
            :if={@running?}
            id="mcp-url-copy"
            text={@agents.url}
            label="Copy MCP URL"
            icon_only
          />
        </div>

        <section id="mcp-agents" class="flex flex-col gap-2">
          <span class="font-mono tracking-label text-base-content/70 text-xs font-semibold uppercase">
            Agents on this machine
          </span>
          <div class="border-base-300 divide-base-content/10 flex flex-col divide-y rounded-lg border px-3">
            <ul
              id="mcp-agent-list"
              phx-update="stream"
              class="divide-base-content/10 divide-y empty:hidden"
            >
              <.agent_row :for={{dom_id, agent} <- @streams.agents} id={dom_id} agent={agent} />
            </ul>
            <div
              id="mcp-agent-other"
              class="grid-cols-[auto_1fr_auto] grid items-center gap-x-2.5 gap-y-1 py-2"
            >
              <McpComponents.agent_logo />
              <span class="text-sm">Another agent</span>
              <McpComponents.copy_text
                id="mcp-setup-prompt"
                text={McpClients.setup_prompt(@agents.url)}
                label="Copy setup prompt"
              />
              <span class="text-base-content/70 col-span-2 col-start-2 text-xs">
                Paste it into any agent and it adds Voyager itself.
              </span>
            </div>
          </div>
          <div class="flex items-center justify-between gap-4 text-xs">
            <span class="text-base-content/70">Only agents found on this machine are listed.</span>
            <a
              id="mcp-docs"
              href={McpComponents.docs_url()}
              target="_blank"
              rel="noopener noreferrer"
              class="text-base-content/70 hover:text-base-content"
            >
              What can agents do?
            </a>
          </div>
        </section>

        <details id="mcp-port" phx-mounted={JS.ignore_attributes(["open"])} class="text-sm">
          <summary class="text-base-content/70 cursor-pointer hover:text-base-content">
            Advanced: port
          </summary>
          <.form
            for={@form}
            id="mcp-port-form"
            phx-change="validate_port"
            phx-submit="save_port"
            phx-target={@myself}
            class="mt-3 flex items-start gap-2"
          >
            <div class="flex-1">
              <.input
                field={@form[:port]}
                type="number"
                placeholder="4040"
                disabled={@port_locked?}
                aria-label="Port"
                class="font-mono text-sm"
              />
            </div>
            <button type="submit" class="btn btn-primary" disabled={@port_locked?}>
              Save port
            </button>
          </.form>
        </details>
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

  attr :id, :string, required: true
  attr :agent, :map, required: true

  defp agent_row(assigns) do
    ~H"""
    <li id={@id} class="grid-cols-[auto_1fr_auto] grid items-center gap-x-2.5 gap-y-1.5 py-2">
      <McpComponents.agent_logo id={@agent.id} />
      <span class="min-w-0 truncate text-sm">
        {@agent.name}
        <span :if={@agent.connection} class="font-mono text-base-content/70 text-xs">
          {McpComponents.client_label(@agent.connection)}
        </span>
      </span>
      <%= cond do %>
        <% @agent.connection -> %>
          <span class="text-success flex items-center gap-1 text-xs font-medium">
            <span class="bg-success size-1.5 rounded-full"></span> Connected
          </span>
          <span class="font-mono text-base-content/70 col-span-2 col-start-2 text-xs">
            {McpComponents.last_call(@agent.connection)}
          </span>
        <% @agent.added? -> %>
          <span id={"#{@id}-added"} class="badge badge-ghost badge-sm">Added</span>
          <span class="font-mono text-base-content/70 col-span-2 col-start-2 text-xs">
            in {@agent.config_path} · no call yet
          </span>
        <% @agent.link -> %>
          <a id={"#{@id}-add"} href={@agent.link} class="btn btn-primary btn-xs">
            Add to {@agent.name}
          </a>
        <% true -> %>
          <span class="text-base-content/70 text-xs">detected</span>
          <div class="border-base-300 bg-base-200 col-span-2 col-start-2 flex min-w-0 items-center gap-1 rounded-md border py-0.5 pr-0.5 pl-2">
            <code
              id={"#{@id}-command"}
              title={@agent.command}
              class="font-mono text-base-content/80 min-w-0 flex-1 truncate text-xs"
            >{@agent.command}</code>
            <.copy_button
              id={"#{@id}-copy"}
              target={"##{@id}-command"}
              icon_only
              label="Copy command"
              size={:sm}
            />
          </div>
      <% end %>
    </li>
    """
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
