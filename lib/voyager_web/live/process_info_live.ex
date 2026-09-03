defmodule VoyagerWeb.ProcessInfoLive do
  @moduledoc """
  Shows a single process on the connected node.

  The cheap, size-bounded reads (overview and the links/monitors relations) are
  fetched on mount. The unbounded terms -- messages, dictionary and state -- can
  be arbitrarily large even truncated, so each is gated behind an explicit
  fetch button and never loaded on mount or on the page-wide refresh unless it
  was already fetched once. `Query` owns the data loading; this module owns
  the async lifecycle and events.
  """

  use VoyagerWeb, :live_view

  import VoyagerWeb.Components.ProcessInfoComponents
  import VoyagerWeb.Components.TermComponents

  alias Phoenix.LiveView.AsyncResult
  alias VoyagerWeb.Formatters
  alias VoyagerWeb.Hooks.TermTreeHook
  alias VoyagerWeb.ProcessInfoLive.Query

  require Logger

  on_mount TermTreeHook

  @impl true
  def mount(%{"pid" => pid_string}, _session, socket) do
    socket
    |> assign(:active_nav, :processes)
    |> assign(:pid_string, pid_string)
    |> assign(:pid, nil)
    |> assign(:info, AsyncResult.loading())
    |> assign(:relations, AsyncResult.loading())
    |> assign(:messages, nil)
    |> assign(:dictionary, nil)
    |> assign(:state, nil)
    |> assign(:last_updated, nil)
    |> resolve_pid(pid_string)
    |> ok()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto flex max-w-screen-2xl flex-col gap-6 p-6 sm:p-8">
      <.node_header
        node_name={@session.node_name}
        last_updated={@last_updated}
        waiting_message="waiting for first fetch…"
      >
        <:actions>
          <button
            type="button"
            id="go-to-supervision-tree"
            class="btn btn-ghost btn-sm gap-2"
            disabled
          >
            Supervision tree <span class="badge badge-primary badge-soft badge-xs">Soon</span>
          </button>
          <.tooltip id="process-info-refresh-tip" position="bottom">
            <button
              type="button"
              id="process-info-refresh"
              phx-click="refresh-all"
              phx-throttle="2000"
              disabled={is_nil(@pid)}
              aria-label="Refresh all fetched data"
              class="btn btn-ghost btn-square toolbar-btn"
            >
              <.icon
                name="icon-rotate-cw"
                class={["toolbar-icon", any_loading?(assigns) && "motion-safe:animate-spin"]}
              />
            </button>
            <:content>Refresh all fetched data</:content>
          </.tooltip>
        </:actions>
      </.node_header>

      <div class="flex flex-wrap items-center gap-3">
        <.link
          id="back-to-processes"
          navigate={~p"/node/#{@session.node_name}/processes"}
          class="btn btn-ghost btn-sm gap-2"
        >
          <.icon name="icon-arrow-left" class="size-4" /> Processes
        </.link>
        <h2 class="font-mono text-base-content truncate text-lg font-semibold">
          {@pid_string}
        </h2>
      </div>

      <div class="grid grid-cols-1 gap-6 lg:grid-cols-2">
        <.overview_card
          info={@info}
          disabled={is_nil(@pid)}
          loading?={loading?(@info) or loading?(@relations)}
        />
        <.relations_card
          relations={@relations}
          node_name={@session.node_name}
          remote_node={@session.node}
        />
      </div>

      <div class="grid grid-cols-1 items-start gap-6 lg:grid-cols-2">
        <.term_card
          :let={state}
          id="process-state"
          title="State"
          result={@state}
          fetch_event="fetch-state"
          fetch_label="Fetch state"
          gate_description="Calls :sys.get_state on the remote node. A busy process or one that does not handle system messages will time out."
          disabled={is_nil(@pid)}
        >
          <.term_inspector
            id="process-state"
            term={state.term}
            state={@term_states["process-state"]}
            truncated?={state.truncated?}
            class="overflow-x-auto"
          />
        </.term_card>

        <div class="flex flex-col gap-6">
          <.term_card
            :let={messages}
            id="process-messages"
            title="Messages"
            muted={queue_len_label(@info)}
            result={@messages}
            fetch_event="fetch-messages"
            fetch_label="Fetch messages"
            gate_description="Copies the mailbox on the remote node before truncating, so a huge mailbox is expensive to read."
            disabled={is_nil(@pid)}
          >
            <p :if={messages.items == []} class="font-mono text-base-content/70 text-xs">
              Mailbox is empty.
            </p>
            <ol
              :if={messages.items != []}
              class="divide-base-content/10 m-0 flex list-none flex-col divide-y p-0"
            >
              <li :for={{message, index} <- Enum.with_index(messages.items)} class="py-2">
                <.term_inspector
                  id={"message-#{index}"}
                  term={message}
                  state={@term_states["message-#{index}"]}
                  class="overflow-x-auto"
                />
              </li>
            </ol>
            <.truncation_note :if={messages.truncated?} id="process-messages-truncated" />
          </.term_card>

          <.term_card
            :let={dictionary}
            id="process-dictionary"
            title="Dictionary"
            muted={bounded_count(@dictionary)}
            result={@dictionary}
            fetch_event="fetch-dictionary"
            fetch_label="Fetch dictionary"
            gate_description="The process dictionary holds arbitrary user terms and can be large; it is truncated on the remote node."
            disabled={is_nil(@pid)}
          >
            <p :if={dictionary.items == []} class="font-mono text-base-content/70 text-xs">
              Dictionary is empty.
            </p>
            <ol
              :if={dictionary.items != []}
              class="divide-base-content/10 m-0 flex list-none flex-col divide-y p-0"
            >
              <li :for={{entry, index} <- Enum.with_index(dictionary.items)} class="py-2">
                <.term_inspector
                  id={"dict-entry-#{index}"}
                  term={entry}
                  state={@term_states["dict-entry-#{index}"]}
                  class="overflow-x-auto"
                />
              </li>
            </ol>
            <.truncation_note :if={dictionary.truncated?} id="process-dictionary-truncated" />
          </.term_card>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("refresh-all", _params, %{assigns: %{pid: pid}} = socket) when is_pid(pid) do
    socket
    |> fetch(:info)
    |> fetch(:relations)
    |> refetch_if_loaded(:messages)
    |> refetch_if_loaded(:dictionary)
    |> refetch_if_loaded(:state)
    |> noreply()
  end

  def handle_event("fetch-overview", _params, %{assigns: %{pid: pid}} = socket)
      when is_pid(pid) do
    socket
    |> fetch(:info)
    |> fetch(:relations)
    |> noreply()
  end

  def handle_event("fetch-messages", _params, %{assigns: %{pid: pid}} = socket)
      when is_pid(pid) do
    socket
    |> fetch(:messages)
    |> noreply()
  end

  def handle_event("fetch-dictionary", _params, %{assigns: %{pid: pid}} = socket)
      when is_pid(pid) do
    socket
    |> fetch(:dictionary)
    |> noreply()
  end

  def handle_event("fetch-state", _params, %{assigns: %{pid: pid}} = socket) when is_pid(pid) do
    socket
    |> fetch(:state)
    |> noreply()
  end

  # Buttons are disabled until the pid resolves; a click can still race that.
  def handle_event(event, _params, socket)
      when event in ~w(refresh-all fetch-overview fetch-messages fetch-dictionary fetch-state) do
    noreply(socket)
  end

  @impl true
  def handle_async(:pid, {:ok, {:ok, pid}}, socket) when is_pid(pid) do
    socket
    |> assign(:pid, pid)
    |> fetch(:info)
    |> fetch(:relations)
    |> noreply()
  end

  def handle_async(:pid, result, socket) do
    reason =
      case result do
        {:ok, {:error, reason}} -> reason
        {:exit, reason} -> reason
      end

    Logger.warning("Failed to resolve pid #{socket.assigns.pid_string}: #{inspect(reason)}")

    socket
    |> assign(:info, AsyncResult.failed(socket.assigns.info, :invalid_pid))
    |> assign(:relations, AsyncResult.failed(socket.assigns.relations, :invalid_pid))
    |> noreply()
  end

  def handle_async(_name, {:exit, {:shutdown, :cancel}}, socket), do: noreply(socket)

  def handle_async(name, {:ok, {:ok, value}}, socket)
      when name in [:info, :relations, :messages, :dictionary, :state] do
    socket
    |> assign(name, AsyncResult.ok(socket.assigns[name], value))
    |> seed_terms(name, value)
    |> assign(:last_updated, DateTime.utc_now())
    |> noreply()
  end

  def handle_async(name, result, socket)
      when name in [:info, :relations, :messages, :dictionary, :state] do
    reason =
      case result do
        {:ok, {:error, reason}} -> reason
        {:exit, reason} -> {:exit, reason}
      end

    Logger.warning(
      "Failed to fetch #{name} for #{socket.assigns.pid_string} on " <>
        "#{inspect(socket.assigns.session.node)}: #{inspect(reason)}"
    )

    socket
    |> assign(name, AsyncResult.failed(socket.assigns[name], reason))
    |> noreply()
  end

  defp resolve_pid(socket, pid_string) do
    node = socket.assigns.session.node

    cond do
      not connected?(socket) ->
        socket

      not Query.valid_pid_string?(pid_string) ->
        socket
        |> assign(:info, AsyncResult.failed(socket.assigns.info, :invalid_pid))
        |> assign(:relations, AsyncResult.failed(socket.assigns.relations, :invalid_pid))

      true ->
        start_async(socket, :pid, fn -> Query.resolve_pid(node, pid_string) end)
    end
  end

  @queries %{
    info: &Query.overview/2,
    relations: &Query.relations/2,
    messages: &Query.messages/2,
    dictionary: &Query.dictionary/2,
    state: &Query.state/2
  }

  defp fetch(socket, name) do
    %{pid: pid, session: %{node: node}} = socket.assigns
    query = Map.fetch!(@queries, name)

    socket
    |> cancel_async(name, {:shutdown, :cancel})
    |> assign(name, mark_loading(socket.assigns[name]))
    |> start_async(name, fn -> query.(node, pid) end)
  end

  defp refetch_if_loaded(socket, name) do
    if socket.assigns[name], do: fetch(socket, name), else: socket
  end

  defp mark_loading(nil), do: AsyncResult.loading()
  defp mark_loading(%AsyncResult{} = result), do: AsyncResult.loading(result)

  defp seed_terms(socket, :state, %{term: term}),
    do: TermTreeHook.put_term(socket, "process-state", term)

  defp seed_terms(socket, :messages, %{items: items}),
    do: seed_term_list(socket, "message", items)

  defp seed_terms(socket, :dictionary, %{items: items}),
    do: seed_term_list(socket, "dict-entry", items)

  defp seed_terms(socket, _name, _value), do: socket

  defp seed_term_list(socket, prefix, items) do
    items
    |> Enum.with_index()
    |> Enum.reduce(socket, fn {term, index}, socket ->
      TermTreeHook.put_term(socket, "#{prefix}-#{index}", term)
    end)
  end

  defp any_loading?(assigns) do
    Enum.any?(
      [assigns.info, assigns.relations, assigns.messages, assigns.dictionary, assigns.state],
      &loading?/1
    )
  end

  defp queue_len_label(%AsyncResult{ok?: true, result: %{message_queue_len: len}}),
    do: "(#{Formatters.format_integer(len)} in queue)"

  defp queue_len_label(_info), do: nil
end
