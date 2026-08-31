defmodule VoyagerWeb.ProcessesLive.ColumnControls do
  @moduledoc """
  Collapsible picker for the columns shown in the process table.

  Mirrors `VoyagerWeb.SupervisionTreeLive.Controls`: the collapsible card and
  checkbox chips are the same, and the selection is routed state — this
  component only builds the path and calls `push_patch/2`, while the parent
  LiveView's `handle_params/3` validates it and triggers the refetch.

  `Voyager.Queries.Processes.required_attrs/0` are rendered checked and disabled
  and are re-added server-side, so they cannot be removed from a hand-edited URL
  either.
  """

  use VoyagerWeb, :live_component

  alias Voyager.Queries.Processes
  alias VoyagerWeb.Components.ProcessComponents
  alias VoyagerWeb.Utils.URL

  @impl true
  def mount(socket) do
    socket
    |> assign(:open?, false)
    |> ok()
  end

  @impl true
  def update(assigns, socket) do
    socket
    |> assign(assigns)
    |> ok()
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:required, Processes.required_attrs())
      |> assign(:optional, Processes.optional_attrs())

    ~H"""
    <div class="card bg-base-100 border-base-200 border shadow-sm">
      <div class="card-body py-3">
        <form
          id={"#{@id}-form"}
          phx-target={@myself}
          phx-change="select_columns"
          phx-submit="select_columns"
        >
          <.collapsible
            id="process-columns"
            phx-target={@myself}
            phx-click="toggle_open"
            open={@open?}
          >
            <:label>
              <h2 class="text-base-content ml-2 text-sm font-semibold leading-8">Columns</h2>
              <span class="badge badge-ghost badge-sm font-mono ml-3">
                {length(@selected)}
              </span>
            </:label>

            <div class="flex flex-wrap gap-2 py-4">
              <%!-- Required columns render checked and disabled: a disabled
                    checkbox submits nothing, so they are re-added server-side. --%>
              <.column_chip
                :for={attr <- @required}
                attr={attr}
                checked={true}
                disabled={true}
              />
              <.column_chip
                :for={attr <- @optional}
                attr={attr}
                checked={attr in @selected}
                disabled={false}
              />
            </div>
          </.collapsible>
        </form>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("toggle_open", _params, socket) do
    socket
    |> assign(:open?, not socket.assigns.open?)
    |> noreply()
  end

  def handle_event("select_columns", params, socket) do
    selected =
      params
      |> Map.get("columns", [])
      |> Enum.map(&safe_atom/1)
      |> Enum.reject(&is_nil/1)
      |> Processes.clamp_attrs()

    socket
    |> push_patch(to: columns_path(socket, selected))
    |> noreply()
  end

  attr :attr, :atom, required: true
  attr :checked, :boolean, required: true
  attr :disabled, :boolean, required: true

  defp column_chip(assigns) do
    ~H"""
    <label
      id={"column-#{@attr}-label"}
      class={[
        "flex items-center gap-2 rounded-lg border px-3 py-1.5 text-sm transition-colors",
        @disabled && "border-base-300 bg-base-200 text-base-content/60 cursor-not-allowed",
        not @disabled && "cursor-pointer",
        (not @disabled and @checked) && "border-primary bg-primary/10 text-primary",
        (not @disabled and not @checked) &&
          "border-base-300 bg-base-200 text-base-content hover:border-primary/50"
      ]}
      title={@disabled && "Always shown"}
    >
      <input
        id={"column-#{@attr}-input"}
        type="checkbox"
        name="columns[]"
        value={to_string(@attr)}
        checked={@checked}
        disabled={@disabled}
        class="checkbox checkbox-xs checkbox-primary"
      />
      <span class="font-mono">{ProcessComponents.column_label(@attr)}</span>
      <.icon :if={@disabled} name="icon-check" class="size-3.5" />
    </label>
    """
  end

  defp columns_path(socket, selected) do
    URL.put_query_param(
      socket.assigns.current_url,
      "columns",
      Enum.map_join(selected, ",", &to_string/1)
    )
  end

  # The checkbox values come from the client, so only known attributes are
  # converted; anything else is dropped rather than creating an atom.
  defp safe_atom(value) do
    Enum.find(Processes.required_attrs() ++ Processes.optional_attrs(), &(to_string(&1) == value))
  end
end
