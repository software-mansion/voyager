defmodule VoyagerWeb.Components.ComingSoon do
  @moduledoc """
  Shared placeholder card for the coming-soon pages.
  """

  use VoyagerWeb, :html

  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :icon, :string, required: true

  def panel(assigns) do
    ~H"""
    <div class="mx-auto flex h-full max-w-screen-2xl flex-col items-center justify-center p-6 sm:p-8">
      <div class="border-base-300 bg-base-100 relative flex w-full max-w-xl flex-col items-center gap-4 rounded-2xl border p-10 text-center shadow-sm">
        <span class="badge badge-primary badge-soft badge-sm absolute top-4 right-4">
          Coming soon
        </span>

        <div class="bg-primary/10 size-16 flex items-center justify-center rounded-full">
          <.icon name={@icon} class="text-primary size-7" />
        </div>

        <h1 class="text-xl font-semibold">{@title}</h1>

        <p class="text-base-content/70 max-w-sm text-sm">{@description}</p>

        <a
          href={waitlist_url()}
          target="_blank"
          rel="noopener noreferrer"
          class="btn btn-primary btn-sm mt-2 shadow-none"
        >
          Join the waiting list
        </a>
      </div>
    </div>
    """
  end

  defp waitlist_url, do: "http://localhost:4000/"
end
