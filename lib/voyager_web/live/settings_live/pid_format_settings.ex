defmodule VoyagerWeb.SettingsLive.PidFormatSettings do
  @moduledoc false
  use VoyagerWeb, :live_component

  alias Voyager.Settings
  alias VoyagerWeb.Formatters
  alias VoyagerWeb.SettingsComponents

  @pid_formats [
    {:distribution, "icon-network", "Distribution", "<123.23.423>",
     "Keeps the remote node index, which identifies a process across a cluster."},
    {:local, "icon-laptop", "Local", "<0.23.423>",
     "Replaces the node index with 0, so you can use it on remote shells."}
  ]

  @impl true
  def mount(socket) do
    socket
    |> assign(:locked?, Settings.locked?(:pid_format))
    |> assign(:pid_format, Voyager.Pid.cached_format())
    |> ok()
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :pid_formats, @pid_formats)

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
              :for={{_format, icon, text, pid_string, description} <- @pid_formats}
              class="list-row flex items-center gap-4"
            >
              <.icon name={icon} class="text-base-content/70 size-4" />
              <div class="list-col-grow">
                <div class="flex flex-wrap items-center gap-2">
                  <span class="text-base-content font-medium">{text}</span>
                  <kbd class="font-mono">{pid_string}</kbd>
                </div>
                <p class="text-base-content/60 text-xs">{description}</p>
              </div>
            </li>
          </ul>
        </div>

        <SettingsComponents.locked_alert id="pid-format-locked" locked?={@locked?} />

        <div id="pid-format-setting" class="join inline-grid grid-cols-2 self-start">
          <button
            :for={{format, icon, text, _pid_string, _description} <- @pid_formats}
            type="button"
            id={"pid-format-#{format}"}
            class={[
              "join-item btn w-full justify-center gap-1.5",
              if(@pid_format == format,
                do: "btn-primary text-primary-content",
                else: "btn-soft text-base-content/70"
              )
            ]}
            aria-pressed={to_string(@pid_format == format)}
            disabled={@locked?}
            phx-click="select"
            phx-value-format={format}
            phx-target={@myself}
          >
            <.icon name={icon} class="size-4" /> {text}
          </button>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("select", %{"format" => format}, socket)
      when format in ~w(distribution local) do
    format = String.to_existing_atom(format)

    if socket.assigns.locked? or socket.assigns.pid_format == format do
      {:noreply, socket}
    else
      case Settings.put(:pid_format, format) do
        {:ok, _setting} ->
          Formatters.put_pid_format(format)

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
end
