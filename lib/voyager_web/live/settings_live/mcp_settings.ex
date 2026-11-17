defmodule VoyagerWeb.SettingsLive.McpSettings do
  @moduledoc false
  use VoyagerWeb, :live_component

  alias Voyager.MCP
  alias Voyager.Services.CodingAgents
  alias Voyager.Services.McpAgents
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
    |> ok()
  end

  @impl true
  def update(%{agents: %McpAgents{} = agents} = assigns, socket) do
    {shown, more} =
      agents.agents
      |> Enum.map(fn agent ->
        Map.put(agent, :recent, Enum.find(agents.recent, &(&1.agent_id == agent.id)))
      end)
      |> Enum.split_with(&(&1.detected? or &1.status == :added or &1.recent != nil))

    socket
    |> assign(assigns)
    |> assign(:shown_agents, shown)
    |> assign(:more_agents, more)
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
              Lets coding agents inspect the node you are connected to.
            </p>
          </div>
          <input
            id="mcp-toggle"
            type="checkbox"
            class="toggle toggle-primary mt-1"
            aria-label="Toggle MCP server"
            checked={@agents.server.alive?}
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
              :if={@agents.server.alive?}
              class="bg-success absolute inline-flex h-full w-full animate-ping rounded-full opacity-75"
            ></span>
            <span class={[
              "relative inline-flex h-1.5 w-1.5 rounded-full",
              if(@agents.server.alive?, do: "bg-success", else: "bg-error")
            ]}></span>
          </span>
          <span id="mcp-url-status">
            {if @agents.server.alive?, do: "Running at #{@agents.server.url}", else: "Stopped"}
          </span>
          <span id="mcp-url" class="hidden">{@agents.server.url}</span>
          <.copy_button
            :if={@agents.server.alive?}
            id="mcp-url-copy"
            target="#mcp-url"
            label="Copy MCP URL"
            icon_only
            size={:sm}
            class="text-base-content/70 hover:text-base-content"
          />
        </div>

        <section id="mcp-agents" class="flex flex-col gap-2">
          <span class="font-mono tracking-label text-base-content/70 text-xs font-semibold uppercase">
            Agents
          </span>
          <div class="border-base-300 divide-base-content/10 flex flex-col divide-y rounded-lg border px-4">
            <ul id="mcp-agent-list" class="divide-base-content/10 divide-y">
              <.agent_row
                :for={agent <- @shown_agents}
                id={"mcp-agent-#{agent.id}"}
                agent={agent}
                target={@myself}
              />
            </ul>
            <details
              :if={@more_agents != []}
              id="mcp-more-agents"
              phx-mounted={JS.ignore_attributes(["open"])}
              class="group py-3"
            >
              <summary class="text-base-content/70 flex cursor-pointer list-none items-center gap-1.5 text-sm hover:text-base-content">
                <.icon
                  name="icon-chevron-right"
                  class="size-4 transition-transform group-open:rotate-90"
                />
                Show {length(@more_agents)} more {if length(@more_agents) == 1,
                  do: "agent",
                  else: "agents"}
              </summary>
              <ul id="mcp-more-agent-list" class="divide-base-content/10 mt-1 divide-y">
                <.agent_row
                  :for={agent <- @more_agents}
                  id={"mcp-agent-#{agent.id}"}
                  agent={agent}
                  target={@myself}
                />
              </ul>
            </details>
            <div id="mcp-agent-other" class="flex items-center gap-3 py-3">
              <McpComponents.agent_logo size={:md} />
              <div class="min-w-0 flex-1">
                <p class="text-sm font-medium">Another agent</p>
                <p class="text-base-content/70 text-xs">
                  Paste the setup prompt into any agent and it adds Voyager itself.
                </p>
              </div>
              <span id="mcp-setup-prompt" class="hidden">
                {CodingAgents.setup_prompt(@agents.server.url)}
              </span>
              <.copy_button
                id="mcp-setup-prompt-copy"
                target="#mcp-setup-prompt"
                label="Copy setup prompt"
              />
            </div>
          </div>
        </section>

        <details id="mcp-port" phx-mounted={JS.ignore_attributes(["open"])} class="group">
          <summary class="text-base-content/70 flex cursor-pointer list-none items-center gap-1.5 text-sm hover:text-base-content">
            <.icon name="icon-chevron-right" class="size-4 transition-transform group-open:rotate-90" />
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
        # The browser already flipped the checkbox; bumping the revision forces a patch that resets it.
        socket
        |> push_flash(:error, "Failed to toggle MCP server: #{inspect(reason)}")
        |> assign(:toggle_revision, socket.assigns.toggle_revision + 1)
        |> noreply()
    end
  end

  def handle_event("add-agent", %{"id" => id}, socket) do
    change_agent(socket, id, &McpAgents.install/1, "add Voyager", fn name ->
      "Voyager added to #{name}. Restart it to load the server."
    end)
  end

  def handle_event("remove-agent", %{"id" => id}, socket) do
    change_agent(socket, id, &McpAgents.remove/1, "remove Voyager", fn name ->
      "Voyager removed from #{name}. Restart it to apply."
    end)
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
  attr :target, :any, required: true

  defp agent_row(assigns) do
    ~H"""
    <li id={@id} class="flex flex-col gap-2 py-3">
      <div class="flex items-center gap-3">
        <.agent_identity agent={@agent} />
        <button
          :if={@agent.status in [:not_added, :outdated]}
          id={"#{@id}-add"}
          type="button"
          phx-click="add-agent"
          phx-value-id={@agent.id}
          phx-target={@target}
          class="btn btn-sm btn-soft btn-primary"
        >
          {if @agent.status == :outdated, do: "Update", else: "Add"}
        </button>
        <span :if={@agent.status == :added} id={"#{@id}-added"} class="badge badge-ghost">
          Added
        </span>
        <button
          :if={@agent.removable?}
          id={"#{@id}-remove"}
          type="button"
          phx-click="remove-agent"
          phx-value-id={@agent.id}
          phx-target={@target}
          title={"Remove Voyager from #{@agent.name}"}
          aria-label={"Remove Voyager from #{@agent.name}"}
          class="btn btn-sm btn-ghost btn-square text-base-content/70 hover:text-error"
        >
          <.icon name="icon-trash" class="size-4" />
        </button>
      </div>
      <p :if={@agent.status == :added} class="font-mono text-base-content/70 pl-11 text-xs">
        in {@agent.path}
      </p>
      <div :if={@agent.status == :manual} id={"#{@id}-manual"} class="flex flex-col gap-1.5 pl-11">
        <p class="text-base-content/70 text-xs">
          Voyager can't edit this file safely. Add this to <span class="font-mono">{@agent.path}</span>:
        </p>
        <div class="border-base-300 bg-base-200 flex items-start gap-1 rounded-lg border py-1 pr-1 pl-3">
          <pre
            id={"#{@id}-snippet"}
            class="font-mono text-base-content/80 min-w-0 flex-1 overflow-x-auto py-1 text-xs"
          >{@agent.snippet}</pre>
          <.copy_button id={"#{@id}-copy"} target={"##{@id}-snippet"} label="Copy config" icon_only />
        </div>
      </div>
    </li>
    """
  end

  attr :agent, :map, required: true

  defp agent_identity(assigns) do
    ~H"""
    <McpComponents.agent_logo id={@agent.id} size={:md} />
    <span class="flex min-w-0 flex-1 flex-col">
      <span class="flex items-center gap-2 text-sm font-medium">
        <span class="truncate">{@agent.name}</span>
        <span :if={@agent.recent} class="font-mono text-base-content/70 truncate text-xs font-normal">
          {@agent.recent.name} {@agent.recent.version}
        </span>
      </span>
      <McpComponents.recently_used :if={@agent.recent} />
    </span>
    """
  end

  defp change_agent(socket, id, change, action, success_message) do
    with {:ok, id} <- CodingAgents.fetch(id),
         :ok <- change.(id) do
      name = Enum.find(socket.assigns.agents.agents, &(&1.id == id)).name

      socket
      |> push_flash(:info, success_message.(name))
      |> noreply()
    else
      :error ->
        {:noreply, socket}

      {:error, reason} ->
        socket
        |> push_flash(:error, "Failed to #{action}: #{format_config_error(reason)}")
        |> noreply()
    end
  end

  defp format_config_error(:invalid_json), do: "the config file is not valid JSON"
  defp format_config_error(:unexpected_shape), do: "the config file has an unexpected shape"

  defp format_config_error(reason) when is_atom(reason),
    do: to_string(:file.format_error(reason))

  defp format_config_error(reason), do: inspect(reason)

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
