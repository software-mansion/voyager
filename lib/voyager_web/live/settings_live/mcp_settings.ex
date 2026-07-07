defmodule VoyagerWeb.SettingsLive.McpSettings do
  @moduledoc false
  use VoyagerWeb, :live_component

  alias Voyager.MCP
  alias Voyager.Settings
  alias VoyagerWeb.FormSchemas.McpPort

  require Logger

  @default_port 4040

  @impl true
  def update(assigns, socket) do
    socket
    |> assign(assigns)
    |> assign_new(:locked?, fn -> Settings.locked?(:mcp_port) end)
    |> assign_new(:form, &mcp_port_form/0)
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
            <p class="text-base-content/60 mt-1 text-sm">
              Exposes node introspection tools to MCP clients over HTTP.
            </p>
          </div>
          <input
            id="mcp-toggle"
            type="checkbox"
            class="toggle toggle-primary mt-1"
            aria-label="Toggle MCP server"
            checked={@status.alive?}
            phx-click="toggle"
            phx-target={@myself}
          />
        </div>

        <div class="text-base-content/60 font-mono flex items-center gap-1.5 text-xs">
          <span class={[
            "h-1.5 w-1.5 rounded-full",
            if(@status.alive?, do: "bg-success", else: "bg-error")
          ]}>
          </span>
          {if @status.alive?, do: "Running at #{@status.url}", else: "Stopped"}
        </div>

        <div :if={@locked?} id="mcp-port-locked" class="alert alert-info text-sm">
          <.icon name="icon-circle-alert" class="size-4" />
          <span>
            This value is set in application config, so changes are disabled.
          </span>
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
                class="font-mono tracking-label text-base-content/50 flex items-center gap-0.5 text-xs font-semibold uppercase"
                for={@form[:port].id}
              >
                Port
              </label>
            </div>
            <.input
              field={@form[:port]}
              type="number"
              placeholder="4040"
              disabled={@locked?}
              class="font-mono text-sm"
            />
          </div>

          <div class="card-actions justify-end">
            <button type="submit" class="btn btn-primary" disabled={@locked?}>
              Save port
            </button>
          </div>
        </.form>
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
        socket
        |> push_flash(:error, "Failed to toggle MCP server: #{inspect(reason)}")
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
        |> assign(:locked?, true)
        |> noreply()

      {:error, :port_in_use} ->
        socket
        |> push_flash(:error, "That port is already in use")
        |> noreply()

      {:error, reason} ->
        Logger.error("Failed to set MCP port: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  defp mcp_port_form do
    %{"port" => Settings.get(:mcp_port, @default_port)}
    |> McpPort.changeset()
    |> to_form(as: :mcp_port)
  end
end
