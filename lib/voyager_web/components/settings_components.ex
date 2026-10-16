defmodule VoyagerWeb.SettingsComponents do
  @moduledoc """
  Shared UI for settings cards.
  """

  use VoyagerWeb, :component

  @doc """
  Info alert shown when a setting is locked by application config.
  """
  attr :id, :string, required: true
  attr :locked?, :boolean, required: true

  def locked_alert(assigns) do
    ~H"""
    <div :if={@locked?} id={@id} class="alert alert-info text-sm">
      <.icon name="icon-info" class="text-info size-4" />
      <span>
        This value is set in application config, so changes are disabled.
      </span>
    </div>
    """
  end

  @doc """
  A card picking one of `options`, each `{value, icon, label, example, description}`.
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :options, :list, required: true
  attr :selected, :atom, required: true
  attr :locked?, :boolean, required: true
  attr :on_select, :string, required: true

  def choice_setting(assigns) do
    ~H"""
    <div id={"#{@id}-settings"} class="card bg-base-100 border-base-200 border shadow-sm">
      <div class="card-body gap-4 p-5">
        <div>
          <h3 class="text-base-content text-sm font-semibold">{@title}</h3>
          <p class="text-base-content/70 mt-1 text-sm">{@description}</p>
          <ul class="list mt-3">
            <li
              :for={{_value, icon, label, example, description} <- @options}
              class="list-row flex items-center gap-4"
            >
              <.icon name={icon} class="text-base-content/70 size-4" />
              <div class="list-col-grow">
                <div class="flex flex-wrap items-center gap-2">
                  <span class="text-base-content font-medium">{label}</span>
                  <kbd :if={example} class="font-mono">{example}</kbd>
                </div>
                <p class="text-base-content/60 text-xs">{description}</p>
              </div>
            </li>
          </ul>
        </div>

        <.locked_alert id={"#{@id}-locked"} locked?={@locked?} />

        <div id={"#{@id}-setting"} class="join inline-grid auto-cols-fr grid-flow-col self-start">
          <button
            :for={{value, icon, label, _example, _description} <- @options}
            type="button"
            id={"#{@id}-#{value}"}
            class={[
              "join-item btn w-full justify-center gap-1.5",
              if(@selected == value,
                do: "btn-primary text-primary-content",
                else: "btn-soft text-base-content/70"
              )
            ]}
            aria-pressed={to_string(@selected == value)}
            disabled={@locked?}
            phx-click={@on_select}
            phx-value-choice={value}
          >
            <.icon name={icon} class="size-4" /> {label}
          </button>
        </div>
      </div>
    </div>
    """
  end
end
