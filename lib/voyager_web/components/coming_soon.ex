defmodule VoyagerWeb.Components.ComingSoon do
  @moduledoc """
  Shared placeholder card for the coming-soon pages. Each page keeps its own
  LiveView module (rather than sharing one) so the built-in
  `phoenix.live_view.mount` telemetry — tagged by `view` module name — can
  tell pages apart, which is what we use to prioritize which feature to
  build next.

  There's no locked-down design for these features yet, so the card sticks
  to a general title/description rather than mocking up UI we might not
  actually ship.
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

        <div class="bg-primary/10 shadow-logo-glow size-16 flex items-center justify-center rounded-full">
          <.icon name={@icon} class="text-primary size-7" />
        </div>

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
    """
  end

  defp waitlist_url, do: "https://voyager.dev/waitlist"
end
