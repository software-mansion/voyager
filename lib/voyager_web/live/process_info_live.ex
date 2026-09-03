defmodule VoyagerWeb.ProcessInfoLive do
  @moduledoc """
  Shows a single process on the connected node.

  The cheap, size-bounded reads (overview and the links/monitors relations) are
  fetched on mount. The unbounded terms -- messages, dictionary and state -- can
  be arbitrarily large even truncated, so each is gated behind an explicit
  fetch button and never loaded on mount or on the page-wide refresh unless it
  was already fetched once. Every fetch is user-triggered, so all of them spend
  from the rate limiter's `:high` bucket.
  """

  use VoyagerWeb, :live_view

  import VoyagerWeb.Components.DetailsPanelComponents,
    only: [overview: 1, memory_and_garbage_collection: 1, section: 1]

  import VoyagerWeb.Components.TermComponents

  alias Phoenix.LiveView.AsyncResult
  alias Voyager.Erpc
  alias Voyager.Services.ProcessInfo
  alias Voyager.Services.ProcessTerm
  alias Voyager.Services.RateLimiter
  alias VoyagerWeb.Components.ProcessInfoComponents
  alias VoyagerWeb.Formatters
  alias VoyagerWeb.Hooks.TermTreeHook

  require Logger

  on_mount TermTreeHook

  @relations_limit 100
  @messages_limit 50
  @dictionary_limit 100

  @pid_format ~r/^<\d+\.\d+\.\d+>$/

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
          <button type="button" id="go-to-supervision-tree" class="btn btn-ghost btn-sm gap-2" disabled>
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
        <ProcessInfoComponents.card id="process-overview-card">
          <:actions>
            <ProcessInfoComponents.refresh_button
              id="overview-refresh"
              event="fetch-overview"
              label="Refresh overview and links"
              loading?={loading?(@info) or loading?(@relations)}
              disabled={is_nil(@pid)}
            />
          </:actions>
          <.overview info={@info} />
          <.memory_and_garbage_collection info={@info} />
        </ProcessInfoComponents.card>

        <ProcessInfoComponents.card id="process-links-card" class="h-max">
          <.async_result :let={relations} assign={@relations}>
            <:loading>
              <.section :for={title <- ["Links", "Monitors", "Monitored by"]} title={title}>
                <ProcessInfoComponents.relations_skeleton />
              </.section>
            </:loading>
            <:failed :let={reason}>
              <.section title="Links">
                <ProcessInfoComponents.fetch_error
                  id="relations-error"
                  message={format_error(reason)}
                />
              </.section>
            </:failed>
            <.section title="Links" muted={bounded_count(relations.links)}>
              <ProcessInfoComponents.identifier_chips
                id="process-links"
                items={relations.links.items}
                total={relations.links.total}
                node_name={@session.node_name}
              />
            </.section>
            <.section title="Monitors" muted={bounded_count(relations.monitors)}>
              <ProcessInfoComponents.identifier_chips
                id="process-monitors"
                items={relations.monitors.items}
                total={relations.monitors.total}
                node_name={@session.node_name}
              />
            </.section>
            <.section title="Monitored by" muted={bounded_count(relations.monitored_by)}>
              <ProcessInfoComponents.identifier_chips
                id="process-monitored-by"
                items={relations.monitored_by.items}
                total={relations.monitored_by.total}
                node_name={@session.node_name}
              />
            </.section>
          </.async_result>
        </ProcessInfoComponents.card>
      </div>

      <div class="grid grid-cols-1 items-start gap-6 lg:grid-cols-2">
        <ProcessInfoComponents.card id="process-state-card">
          <:actions>
            <ProcessInfoComponents.refresh_button
              :if={@state}
              id="state-refresh"
              event="fetch-state"
              label="Refresh state"
              loading?={loading?(@state)}
              disabled={is_nil(@pid)}
            />
          </:actions>
          <.section title="State">
            <ProcessInfoComponents.fetch_gate
              :if={is_nil(@state)}
              id="fetch-state"
              event="fetch-state"
              label="Fetch state"
              disabled={is_nil(@pid)}
              description="Calls :sys.get_state on the remote node. A busy process or one that does not handle system messages will time out."
            />
            <.async_result :let={state} :if={@state} assign={@state}>
              <:loading><ProcessInfoComponents.term_skeleton id="state-skeleton" /></:loading>
              <:failed :let={reason}>
                <ProcessInfoComponents.fetch_error id="state-error" message={format_error(reason)} />
              </:failed>
              <.term_inspector
                id="process-state"
                term={state.term}
                state={@term_states["process-state"]}
                truncated?={state.truncated?}
              />
            </.async_result>
          </.section>
        </ProcessInfoComponents.card>

        <div class="flex flex-col gap-6">
          <ProcessInfoComponents.card id="process-messages-card">
            <:actions>
              <ProcessInfoComponents.refresh_button
                :if={@messages}
                id="messages-refresh"
                event="fetch-messages"
                label="Refresh messages"
                loading?={loading?(@messages)}
                disabled={is_nil(@pid)}
              />
            </:actions>
            <.section title="Messages" muted={queue_len_label(@info)}>
              <ProcessInfoComponents.fetch_gate
                :if={is_nil(@messages)}
                id="fetch-messages"
                event="fetch-messages"
                label="Fetch messages"
                disabled={is_nil(@pid)}
                description="Copies the mailbox on the remote node before truncating, so a huge mailbox is expensive to read."
              />
              <.async_result :let={messages} :if={@messages} assign={@messages}>
                <:loading><ProcessInfoComponents.term_skeleton id="messages-skeleton" /></:loading>
                <:failed :let={reason}>
                  <ProcessInfoComponents.fetch_error
                    id="messages-error"
                    message={format_error(reason)}
                  />
                </:failed>
                <p :if={messages.items == []} class="font-mono text-base-content/70 text-xs">
                  Mailbox is empty.
                </p>
                <ol :if={messages.items != []} class="divide-base-content/10 m-0 flex list-none flex-col divide-y p-0">
                  <li :for={{message, index} <- Enum.with_index(messages.items)} class="py-2">
                    <.term_inspector
                      id={"message-#{index}"}
                      term={message}
                      state={@term_states["message-#{index}"]}
                    />
                  </li>
                </ol>
                <.truncation_note :if={messages.truncated?} id="messages-truncated" />
              </.async_result>
            </.section>
          </ProcessInfoComponents.card>

          <ProcessInfoComponents.card id="process-dictionary-card">
            <:actions>
              <ProcessInfoComponents.refresh_button
                :if={@dictionary}
                id="dictionary-refresh"
                event="fetch-dictionary"
                label="Refresh dictionary"
                loading?={loading?(@dictionary)}
                disabled={is_nil(@pid)}
              />
            </:actions>
            <.section title="Dictionary" muted={bounded_count(@dictionary)}>
              <ProcessInfoComponents.fetch_gate
                :if={is_nil(@dictionary)}
                id="fetch-dictionary"
                event="fetch-dictionary"
                label="Fetch dictionary"
                disabled={is_nil(@pid)}
                description="The process dictionary holds arbitrary user terms and can be large; it is truncated on the remote node."
              />
              <.async_result :let={dictionary} :if={@dictionary} assign={@dictionary}>
                <:loading><ProcessInfoComponents.term_skeleton id="dictionary-skeleton" /></:loading>
                <:failed :let={reason}>
                  <ProcessInfoComponents.fetch_error
                    id="dictionary-error"
                    message={format_error(reason)}
                  />
                </:failed>
                <p :if={dictionary.items == []} class="font-mono text-base-content/70 text-xs">
                  Dictionary is empty.
                </p>
                <ol :if={dictionary.items != []} class="divide-base-content/10 m-0 flex list-none flex-col divide-y p-0">
                  <li :for={{entry, index} <- Enum.with_index(dictionary.items)} class="py-2">
                    <.term_inspector
                      id={"dict-entry-#{index}"}
                      term={entry}
                      state={@term_states["dict-entry-#{index}"]}
                    />
                  </li>
                </ol>
                <.truncation_note :if={dictionary.truncated?} id="dictionary-truncated" />
              </.async_result>
            </.section>
          </ProcessInfoComponents.card>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("refresh-all", _params, %{assigns: %{pid: pid}} = socket) when is_pid(pid) do
    socket
    |> fetch_overview()
    |> fetch_relations()
    |> refetch_if_loaded(:messages, &fetch_messages/1)
    |> refetch_if_loaded(:dictionary, &fetch_dictionary/1)
    |> refetch_if_loaded(:state, &fetch_state/1)
    |> noreply()
  end

  def handle_event("fetch-overview", _params, %{assigns: %{pid: pid}} = socket) when is_pid(pid) do
    socket
    |> fetch_overview()
    |> fetch_relations()
    |> noreply()
  end

  def handle_event("fetch-messages", _params, %{assigns: %{pid: pid}} = socket) when is_pid(pid) do
    socket
    |> fetch_messages()
    |> noreply()
  end

  def handle_event("fetch-dictionary", _params, %{assigns: %{pid: pid}} = socket)
      when is_pid(pid) do
    socket
    |> fetch_dictionary()
    |> noreply()
  end

  def handle_event("fetch-state", _params, %{assigns: %{pid: pid}} = socket) when is_pid(pid) do
    socket
    |> fetch_state()
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
    |> fetch_overview()
    |> fetch_relations()
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

  attr :id, :string, required: true

  defp truncation_note(assigns) do
    ~H"""
    <p id={@id} class="text-base-content/70 flex items-center gap-1.5 text-xs">
      <.icon name="icon-info" class="size-3.5 shrink-0" />
      Truncated on the remote node — some entries or values are not shown.
    </p>
    """
  end

  # A pid string names a process only on the node that renders it, so it must
  # be turned back into a pid by the remote node itself, not locally.
  defp resolve_pid(socket, pid_string) do
    node = socket.assigns.session.node

    cond do
      not connected?(socket) ->
        socket

      not Regex.match?(@pid_format, pid_string) ->
        socket
        |> assign(:info, AsyncResult.failed(socket.assigns.info, :invalid_pid))
        |> assign(:relations, AsyncResult.failed(socket.assigns.relations, :invalid_pid))

      true ->
        charlist = String.to_charlist(pid_string)
        start_async(socket, :pid, fn -> Erpc.safe_call(node, :erlang, :list_to_pid, [charlist]) end)
    end
  end

  defp fetch_overview(socket) do
    %{pid: pid, session: %{node: node}} = socket.assigns

    socket
    |> cancel_async(:info, {:shutdown, :cancel})
    |> assign(:info, AsyncResult.loading(socket.assigns.info))
    |> start_async(:info, fn ->
      rate_limited(fn ->
        with {:ok, info} <- ProcessInfo.fetch(node, pid) do
          {:ok, Map.put(info, :label, fetch_label(node, pid))}
        end
      end)
    end)
  end

  defp fetch_relations(socket) do
    %{pid: pid, session: %{node: node}} = socket.assigns

    socket
    |> cancel_async(:relations, {:shutdown, :cancel})
    |> assign(:relations, AsyncResult.loading(socket.assigns.relations))
    |> start_async(:relations, fn ->
      rate_limited(fn ->
        with {:ok, links} <- ProcessInfo.fetch_links(node, pid, @relations_limit),
             {:ok, monitors} <- ProcessInfo.fetch_monitors(node, pid, @relations_limit),
             {:ok, monitored_by} <-
               ProcessInfo.fetch_monitored_by(node, pid, @relations_limit) do
          {:ok, %{links: links, monitors: monitors, monitored_by: monitored_by}}
        end
      end)
    end)
  end

  defp fetch_messages(socket) do
    %{pid: pid, session: %{node: node}} = socket.assigns

    socket
    |> cancel_async(:messages, {:shutdown, :cancel})
    |> assign(:messages, mark_loading(socket.assigns.messages))
    |> start_async(:messages, fn ->
      rate_limited(fn -> ProcessTerm.fetch_messages(node, pid, @messages_limit) end)
    end)
  end

  defp fetch_dictionary(socket) do
    %{pid: pid, session: %{node: node}} = socket.assigns

    socket
    |> cancel_async(:dictionary, {:shutdown, :cancel})
    |> assign(:dictionary, mark_loading(socket.assigns.dictionary))
    |> start_async(:dictionary, fn ->
      rate_limited(fn -> ProcessInfo.fetch_dictionary(node, pid, @dictionary_limit) end)
    end)
  end

  defp fetch_state(socket) do
    %{pid: pid, session: %{node: node}} = socket.assigns

    socket
    |> cancel_async(:state, {:shutdown, :cancel})
    |> assign(:state, mark_loading(socket.assigns.state))
    |> start_async(:state, fn ->
      rate_limited(fn -> ProcessTerm.fetch_state(node, pid) end)
    end)
  end

  # A label is an arbitrary term needing the agent's remote truncation; a node
  # without the agent simply has no label to show -- it must not fail the
  # overview.
  defp fetch_label(node, pid) do
    case ProcessInfo.fetch_label(node, pid) do
      {:ok, %{term: term}} -> term
      {:error, _reason} -> nil
    end
  end

  defp refetch_if_loaded(socket, name, fetch) do
    if socket.assigns[name], do: fetch.(socket), else: socket
  end

  defp mark_loading(nil), do: AsyncResult.loading()
  defp mark_loading(%AsyncResult{} = result), do: AsyncResult.loading(result)

  defp rate_limited(fun) do
    case RateLimiter.run(:high, fun) do
      {:ok, result, _elapsed_us} -> result
      {:error, :rate_limited, _retry_after_ms} -> {:error, :rate_limited}
    end
  end

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

  defp loading?(%AsyncResult{loading: loading}), do: loading != nil
  defp loading?(_result), do: false

  defp any_loading?(assigns) do
    Enum.any?(
      [assigns.info, assigns.relations, assigns.messages, assigns.dictionary, assigns.state],
      &loading?/1
    )
  end

  defp bounded_count(result), do: ProcessInfoComponents.bounded_count(result)

  defp queue_len_label(%AsyncResult{ok?: true, result: %{message_queue_len: len}}),
    do: "(#{Formatters.format_integer(len)} in queue)"

  defp queue_len_label(_info), do: nil

  defp format_error(:invalid_pid), do: "No process with this pid exists on the node."
  defp format_error(:dead), do: "The process is no longer alive."
  defp format_error(:timeout), do: "The process did not reply in time."
  defp format_error(:no_state), do: "This process does not expose a state."
  defp format_error(:rate_limited), do: "Too many requests. Wait a moment and retry."
  defp format_error(:noconnection), do: "Node is unreachable."

  defp format_error({:remote_exception, :undef}),
    do: "The Voyager agent is not loaded on this node."

  defp format_error(_reason), do: "Failed to fetch process information."
end
