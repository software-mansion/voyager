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
end
