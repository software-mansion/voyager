defmodule VoyagerWeb.ProcessDetailsLive do
  @moduledoc """
  Placeholder for the process info page, reached from the process list.

  The real page is VOY-25; this only holds the route so selecting a process in
  the list navigates somewhere sensible. It shows which process was selected and
  a way back, and deliberately fetches nothing.
  """

  use VoyagerWeb, :live_view

  @impl true
  def mount(%{"pid" => pid_string} = params, _session, socket) do
    socket
    |> assign(:active_nav, :processes)
    |> assign(:pid_string, pid_string)
    |> assign(:return_to, return_to(params["return_to"], socket.assigns.session.node_name))
    |> ok()
  end

  # Only a local path is accepted, so a crafted `return_to` cannot send the user
  # to another host; anything else falls back to the unconfigured list.
  defp return_to("/" <> _rest = path, node_name) do
    if String.starts_with?(path, "//"), do: fallback_path(node_name), else: path
  end

  defp return_to(_value, node_name), do: fallback_path(node_name)

  defp fallback_path(node_name), do: ~p"/node/#{node_name}/processes"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto flex h-full max-w-screen-2xl flex-col gap-4 p-6 sm:p-8">
      <div class="flex flex-wrap items-center gap-3">
        <.link
          id="back-to-processes"
          navigate={@return_to}
          class="btn btn-ghost btn-sm gap-2"
        >
          <.icon name="icon-arrow-left" class="size-4" /> Processes
        </.link>
        <h1 class="font-mono text-base-content truncate text-lg font-semibold">
          {@pid_string}
        </h1>
      </div>

      <div class="flex flex-1 items-center justify-center">
        <div class="border-base-300 bg-base-100 relative flex w-full max-w-xl flex-col items-center gap-4 rounded-2xl border p-10 text-center shadow-sm">
          <span class="badge badge-primary badge-soft badge-sm absolute top-4 right-4">
            Coming soon
          </span>

          <div class="bg-primary/10 size-16 flex items-center justify-center rounded-full">
            <.icon name="icon-cpu" class="text-primary size-7" />
          </div>

          <h2 class="text-xl font-semibold">Process info</h2>

          <p class="text-base-content/70 max-w-sm text-sm">
            Details for <span class="font-mono text-base-content">{@pid_string}</span>
            will appear here.
          </p>
        </div>
      </div>
    </div>
    """
  end
end
