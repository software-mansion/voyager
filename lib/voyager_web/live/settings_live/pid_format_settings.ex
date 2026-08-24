defmodule VoyagerWeb.SettingsLive.PidFormatSettings do
  @moduledoc false
  use VoyagerWeb, :live_component

  alias Voyager.Settings
  alias VoyagerWeb.SettingsComponents

  @impl true
  def mount(socket) do
    socket
    |> assign(:locked?, Settings.locked?(:pid_format))
    |> ok()
  end

  @impl true
  def update(%{id: id, pid_format: pid_format}, socket) do
    socket
    |> assign(:id, id)
    |> assign(:pid_format, pid_format)
    |> ok()
  end

  @impl true
  def render(assigns) do
    data = [
      {"icon-network", "Distribution", "<123.23.423>",
       "Keeps the remote node index, which identifies a process across a cluster."},
      {"icon-laptop", "Local", "<0.23.423>",
       "Replaces the node index with <span class='font-mono'>0</span>, so you can use it on remote shells."}
    ]

    assigns = assign(assigns, :data, data)

    ~H"""
    <div id={@id} class="card bg-base-100 border-base-200 border shadow-sm">
      <div class="card-body gap-4 p-5">
        <div>
          <h3 class="text-base-content text-sm font-semibold">PID format</h3>
          <p class="text-base-content/70 mt-1 text-sm">
            Choose how process identifiers are shown in the Voyager UI.
          </p>
          <ul class="list mt-3">
            <li
              :for={{icon, text, pid_string, description} <- @data}
              class="list-row flex items-center gap-4"
            >
              <.icon name={icon} class="text-base-content/70 size-4" />
              <div class="list-col-grow">
                <div class="flex flex-wrap items-center gap-2">
                  <span class="text-base-content font-medium">{text}</span>
                  <kbd class="font-mono">{pid_string}</kbd>
                </div>
                <p class="text-base-content/60 text-xs">
                  {raw(description)}
                </p>
              </div>
            </li>
          </ul>
        </div>

        <SettingsComponents.locked_alert id="pid-format-locked" locked?={@locked?} />

        <div
          id="pid-format-setting"
          class="join inline-grid grid-cols-2 self-start"
        >
          <button
            type="button"
            id="pid-format-distribution"
            class={format_button_class(@pid_format == :distribution)}
            aria-pressed={to_string(@pid_format == :distribution)}
            disabled={@locked?}
            phx-click="select"
            phx-value-format="distribution"
            phx-target={@myself}
          >
            <.icon name="icon-network" class="size-4" /> Distribution
          </button>
          <button
            type="button"
            id="pid-format-local"
            class={format_button_class(@pid_format == :local)}
            aria-pressed={to_string(@pid_format == :local)}
            disabled={@locked?}
            phx-click="select"
            phx-value-format="local"
            phx-target={@myself}
          >
            <.icon name="icon-laptop" class="size-4" /> Local
          </button>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("select", %{"format" => "distribution"}, socket) do
    put_format(socket, :distribution)
  end

  def handle_event("select", %{"format" => "local"}, socket) do
    put_format(socket, :local)
  end

  defp put_format(socket, format) do
    cond do
      socket.assigns.locked? ->
        {:noreply, socket}

      socket.assigns.pid_format == format ->
        {:noreply, socket}

      true ->
        case Settings.put(:pid_format, format, broadcast?: true) do
          {:ok, _setting} ->
            socket
            |> assign(:pid_format, format)
            |> noreply()

          {:error, _} ->
            socket
            |> push_flash(:error, "Failed to update PID format")
            |> noreply()
        end
    end
  end

  defp format_button_class(active?) do
    [
      "join-item btn w-full justify-center gap-1.5",
      if(active?,
        do: "btn-primary text-primary-content",
        else: "btn-soft text-base-content/70"
      )
    ]
  end
end
