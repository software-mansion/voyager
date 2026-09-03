defmodule VoyagerWeb.Components.ProcessInfoComponents do
  @moduledoc """
  Cards and lists for the process info page.
  """

  use VoyagerWeb, :component

  alias Phoenix.LiveView.AsyncResult
  alias VoyagerWeb.Formatters

  @doc """
  A page card. `:actions` floats in the top-right corner so section headings
  rendered by the body keep their own layout.
  """
  attr :id, :string, required: true
  attr :class, :any, default: nil
  slot :actions
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <div id={@id} class={["card bg-base-100 border-base-200 border shadow-sm" | List.wrap(@class)]}>
      <div class="card-body relative gap-5 p-5">
        <div :if={@actions != []} class="absolute right-4 top-3.5 z-10 flex items-center gap-1.5">
          {render_slot(@actions)}
        </div>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :event, :string, required: true
  attr :label, :string, required: true
  attr :loading?, :boolean, required: true
  attr :disabled, :boolean, default: false

  def refresh_button(assigns) do
    ~H"""
    <.tooltip id={"#{@id}-tip"} position="bottom">
      <button
        type="button"
        id={@id}
        phx-click={@event}
        phx-throttle="1000"
        disabled={@disabled}
        aria-label={@label}
        class="btn btn-ghost btn-square btn-sm"
      >
        <.icon name="icon-rotate-cw" class={["size-4", @loading? && "motion-safe:animate-spin"]} />
      </button>
      <:content>{@label}</:content>
    </.tooltip>
    """
  end

  @doc """
  The explicit-fetch gate shown before a potentially heavy read is requested.
  """
  attr :id, :string, required: true
  attr :event, :string, required: true
  attr :label, :string, required: true
  attr :description, :string, required: true
  attr :disabled, :boolean, default: false

  def fetch_gate(assigns) do
    ~H"""
    <div class="border-base-content/10 flex flex-col items-center gap-3 rounded-lg border border-dashed px-4 py-6 text-center">
      <p class="text-base-content/70 max-w-sm text-xs">{@description}</p>
      <button type="button" id={@id} phx-click={@event} disabled={@disabled} class="btn btn-primary btn-sm">
        {@label}
      </button>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :message, :string, required: true

  def fetch_error(assigns) do
    ~H"""
    <div id={@id} class="alert alert-error border px-3 py-2.5 text-xs">
      <.icon name="icon-circle-alert" class="text-error size-4 shrink-0" />
      {@message}
    </div>
    """
  end

  @doc """
  A flat list of process identifiers. Pids become links to their own process
  info page; ports, references and remote names are listed as plain chips.
  """
  attr :id, :string, required: true
  attr :items, :list, required: true
  attr :total, :integer, required: true
  attr :node_name, :string, required: true

  def identifier_chips(assigns) do
    assigns = assign(assigns, :overflow, max(assigns.total - length(assigns.items), 0))

    ~H"""
    <div id={@id} class="flex flex-col gap-2">
      <p :if={@items == []} class="font-mono text-base-content/70 text-xs">None</p>
      <div :if={@items != []} class="flex flex-wrap gap-1.5">
        <%= for item <- Enum.map(@items, &identifier_entry/1) do %>
          <.link
            :if={item.pid?}
            navigate={~p"/node/#{@node_name}/processes/#{item.text}"}
            class="border-base-content/70 bg-base-200 text-base-content font-mono hover:border-primary hover:text-primary inline-flex items-center gap-1.5 rounded-md border px-2.5 py-1 text-xs transition-colors"
          >
            <span class="bg-primary h-1.5 w-1.5 rounded-full" />
            {item.text}
          </.link>
          <span
            :if={not item.pid?}
            class="border-base-content/40 bg-base-200 text-base-content/80 font-mono inline-flex items-center rounded-md border px-2.5 py-1 text-xs"
          >
            {item.text}
          </span>
        <% end %>
      </div>
      <p :if={@overflow > 0} class="font-mono text-base-content/70 text-xs">
        +{Formatters.format_integer(@overflow)} more on the remote node
      </p>
    </div>
    """
  end

  def relations_skeleton(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-1.5">
      <div :for={_ <- 1..3} class="skeleton h-6 w-16 rounded" />
    </div>
    """
  end

  attr :id, :string, required: true

  def term_skeleton(assigns) do
    ~H"""
    <div id={@id} class="flex flex-col gap-2">
      <div class="skeleton h-3 w-2/3 rounded" />
      <div class="skeleton h-3 w-1/2 rounded" />
      <div class="skeleton h-3 w-3/5 rounded" />
    </div>
    """
  end

  @doc """
  Formats the `muted` counter of a section from a bounded result, or from an
  `AsyncResult` holding one.
  """
  @spec bounded_count(AsyncResult.t() | map() | nil) :: String.t() | nil
  def bounded_count(%AsyncResult{ok?: true, result: %{total: total}}),
    do: "(#{Formatters.format_integer(total)})"

  def bounded_count(%{total: total}), do: "(#{Formatters.format_integer(total)})"
  def bounded_count(_result), do: nil

  # Monitor entries arrive as `{:process, target}` / `{:port, port}`; links and
  # monitored-by entries as bare pids and ports.
  defp identifier_entry({:process, target}), do: identifier_entry(target)
  defp identifier_entry({:port, port}), do: identifier_entry(port)

  defp identifier_entry(pid) when is_pid(pid),
    do: %{pid?: true, text: Formatters.format_pid(pid)}

  defp identifier_entry({name, node}) when is_atom(name),
    do: %{pid?: false, text: "#{inspect(name)} on #{node}"}

  defp identifier_entry(other), do: %{pid?: false, text: inspect(other)}
end
