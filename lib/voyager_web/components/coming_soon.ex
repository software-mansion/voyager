defmodule VoyagerWeb.Components.ComingSoon do
  @moduledoc """
  Shared preview card for the coming-soon placeholder pages. Each page keeps
  its own LiveView module (rather than sharing one) so the built-in
  `phoenix.live_view.mount` telemetry — tagged by `view` module name — can
  tell pages apart, which is what we use to prioritize which feature to
  build next.
  """

  use VoyagerWeb, :html

  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :icon, :string, required: true

  def panel(assigns) do
    ~H"""
    <div class="mx-auto flex h-full max-w-screen-2xl flex-col items-center justify-center p-6 sm:p-8">
      <div class="border-base-300 bg-base-100 relative w-full max-w-2xl overflow-hidden rounded-2xl border shadow-sm">
        <div class="blur-[1px] pointer-events-none space-y-3 p-6 opacity-40" aria-hidden="true">
          <div class="skeleton h-6 w-1/3"></div>
          <div class="skeleton h-4 w-full"></div>
          <div class="skeleton h-4 w-5/6"></div>
          <div class="skeleton h-28 w-full"></div>
          <div class="skeleton h-4 w-2/3"></div>
        </div>

        <div class="bg-base-100/80 absolute inset-0 flex flex-col items-center justify-center gap-3 p-6 text-center backdrop-blur-sm">
          <.icon name={@icon} class="text-primary size-8" />
          <span class="badge badge-primary badge-soft">Coming soon</span>
          <h1 class="text-xl font-semibold">{@title}</h1>
          <p class="text-base-content/70 max-w-sm text-sm">{@description}</p>
          <a
            href={waitlist_url()}
            target="_blank"
            rel="noopener noreferrer"
            class="btn btn-primary btn-sm mt-2"
          >
            Join the waiting list
          </a>
        </div>
      </div>
    </div>
    """
  end

  defp waitlist_url, do: "https://voyager.dev/waitlist"
end
