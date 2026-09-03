defmodule VoyagerWeb.Components.ProcessInfoComponents do
  @moduledoc """
  Cards and lists for the process info page.

  The page-specific cards (`overview_card/1`, `relations_card/1`,
  `term_card/1`) render straight from the async assigns the LiveView owns; the
  rest are generic building blocks.
  """

  use VoyagerWeb, :component

  import VoyagerWeb.Components.DetailsPanelComponents,
    only: [overview: 1, memory_and_garbage_collection: 1, section: 1]

  alias Phoenix.LiveView.AsyncResult
  alias VoyagerWeb.Formatters

  @doc """
  The overview card: the same bounded fields the supervision-tree details
  panel shows, plus memory and GC.
  """
  attr :info, AsyncResult, required: true
  attr :disabled, :boolean, required: true
  attr :loading?, :boolean, required: true

  def overview_card(assigns) do
    ~H"""
    <.card id="process-overview-card">
      <:actions>
        <.refresh_button
          id="process-overview-refresh"
          event="fetch-overview"
          label="Refresh overview and links"
          loading?={@loading?}
          disabled={@disabled}
        />
      </:actions>
      <.overview info={@info} />
      <.memory_and_garbage_collection info={@info} />
    </.card>
    """
  end

  @doc """
  The links / monitors / monitored-by card.
  """
  attr :relations, AsyncResult, required: true
  attr :node_name, :string, required: true
  attr :remote_node, :atom, required: true

  def relations_card(assigns) do
    ~H"""
    <.card id="process-links-card" class="h-max">
      <.async_result :let={relations} assign={@relations}>
        <:loading>
          <.section :for={title <- ["Links", "Monitors", "Monitored by"]} title={title}>
            <div class="flex flex-wrap gap-1.5">
              <div :for={_ <- 1..3} class="skeleton h-6 w-16 rounded" />
            </div>
          </.section>
        </:loading>
        <:failed :let={reason}>
          <.section title="Links">
            <.fetch_error id="process-links-error" message={error_message(reason)} />
          </.section>
        </:failed>
        <.section
          :for={
            {title, id, bounded} <- [
              {"Links", "process-links", relations.links},
              {"Monitors", "process-monitors", relations.monitors},
              {"Monitored by", "process-monitored-by", relations.monitored_by}
            ]
          }
          title={title}
          muted={bounded_count(bounded)}
        >
          <.identifier_chips
            id={id}
            items={bounded.items}
            total={bounded.total}
            node_name={@node_name}
            remote_node={@remote_node}
          />
        </.section>
      </.async_result>
    </.card>
    """
  end

  @doc """
  A card for one gated, unbounded term fetch (state, messages, dictionary).

  `result` is `nil` until the first fetch, which renders the explicit-fetch
  gate; afterwards the card carries its own refresh button and renders the
  loaded value through the inner block.
  """
  attr :id, :string, required: true, doc: "base for the card, button and error DOM ids"
  attr :title, :string, required: true
  attr :muted, :string, default: nil
  attr :result, :any, required: true, doc: "nil or an AsyncResult"
  attr :fetch_event, :string, required: true
  attr :fetch_label, :string, required: true
  attr :gate_description, :string, required: true
  attr :disabled, :boolean, required: true
  slot :inner_block, required: true

  def term_card(assigns) do
    ~H"""
    <.card id={"#{@id}-card"}>
      <:actions>
        <.refresh_button
          :if={@result}
          id={"#{@id}-refresh"}
          event={@fetch_event}
          label={"Refresh #{String.downcase(@title)}"}
          loading?={loading?(@result)}
          disabled={@disabled}
        />
      </:actions>
      <.section title={@title} muted={@muted}>
        <.fetch_gate
          :if={is_nil(@result)}
          id={"#{@id}-fetch"}
          event={@fetch_event}
          label={@fetch_label}
          description={@gate_description}
          disabled={@disabled}
        />
        <.async_result :let={value} :if={@result} assign={@result}>
          <:loading>
            <div id={"#{@id}-skeleton"} class="flex flex-col gap-2">
              <div class="skeleton h-3 w-2/3 rounded" />
              <div class="skeleton h-3 w-1/2 rounded" />
              <div class="skeleton h-3 w-3/5 rounded" />
            </div>
          </:loading>
          <:failed :let={reason}>
            <.fetch_error id={"#{@id}-error"} message={error_message(reason)} />
          </:failed>
          {render_slot(@inner_block, value)}
        </.async_result>
      </.section>
    </.card>
    """
  end

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
        <div :if={@actions != []} class="absolute top-3.5 right-4 z-10 flex items-center gap-1.5">
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
      <button
        type="button"
        id={@id}
        phx-click={@event}
        disabled={@disabled}
        class="btn btn-primary btn-sm"
      >
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

  attr :id, :string, required: true

  def truncation_note(assigns) do
    ~H"""
    <p id={@id} class="text-base-content/70 flex items-center gap-1.5 text-xs">
      <.icon name="icon-info" class="size-3.5 shrink-0" />
      Truncated on the remote node — some entries or values are not shown.
    </p>
    """
  end

  @doc """
  A flat list of process identifiers. Pids living on the inspected node become
  links to their own process info page; ports, references, remote names and
  pids of other nodes are listed as plain chips.
  """
  attr :id, :string, required: true
  attr :items, :list, required: true
  attr :total, :integer, required: true
  attr :node_name, :string, required: true
  attr :remote_node, :atom, required: true

  def identifier_chips(assigns) do
    assigns = assign(assigns, :overflow, max(assigns.total - length(assigns.items), 0))

    ~H"""
    <div id={@id} class="flex flex-col gap-2">
      <p :if={@items == []} class="font-mono text-base-content/70 text-xs">None</p>
      <div :if={@items != []} class="flex flex-wrap gap-1.5">
        <%= for item <- Enum.map(@items, &identifier_entry(&1, @remote_node)) do %>
          <.link
            :if={item.pid?}
            navigate={~p"/node/#{@node_name}/processes/#{item.text}"}
            class="border-base-content/70 bg-base-200 text-base-content font-mono inline-flex items-center gap-1.5 rounded-md border px-2.5 py-1 text-xs transition-colors hover:border-primary hover:text-primary"
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

  @doc """
  Formats the `muted` counter of a section from a bounded result, or from an
  `AsyncResult` holding one.
  """
  @spec bounded_count(AsyncResult.t() | map() | nil) :: String.t() | nil
  def bounded_count(%AsyncResult{ok?: true, result: %{total: total}}),
    do: "(#{Formatters.format_integer(total)})"

  def bounded_count(%{total: total}), do: "(#{Formatters.format_integer(total)})"
  def bounded_count(_result), do: nil

  @spec loading?(AsyncResult.t() | nil) :: boolean()
  def loading?(%AsyncResult{loading: loading}), do: loading != nil
  def loading?(_result), do: false

  @spec error_message(term()) :: String.t()
  def error_message(:invalid_pid), do: "No process with this pid exists on the node."
  def error_message(:dead), do: "The process is no longer alive."
  def error_message(:timeout), do: "The process did not reply in time."
  def error_message(:no_state), do: "This process does not expose a state."
  def error_message(:rate_limited), do: "Too many requests. Wait a moment and retry."
  def error_message(:noconnection), do: "Node is unreachable."

  def error_message({:remote_exception, :undef}),
    do: "The Voyager agent is not loaded on this node."

  def error_message(_reason), do: "Failed to fetch process information."

  # Monitor entries arrive as `{:process, target}` / `{:port, port}`; links and
  # monitored-by entries as bare pids and ports.
  defp identifier_entry({:process, target}, remote_node),
    do: identifier_entry(target, remote_node)

  defp identifier_entry({:port, port}, remote_node), do: identifier_entry(port, remote_node)

  defp identifier_entry(pid, remote_node) when is_pid(pid) do
    if node(pid) == remote_node do
      %{pid?: true, text: Formatters.format_pid_local(pid)}
    else
      %{pid?: false, text: "#{Formatters.format_pid_local(pid)} on #{node(pid)}"}
    end
  end

  defp identifier_entry({name, node}, _remote_node) when is_atom(name),
    do: %{pid?: false, text: "#{inspect(name)} on #{node}"}

  defp identifier_entry(other, _remote_node), do: %{pid?: false, text: inspect(other)}
end
