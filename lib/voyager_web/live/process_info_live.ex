defmodule VoyagerWeb.ProcessInfoLive do
  @moduledoc """
  Shows a single process on the connected node, one tab per section.

  The cheap, size-bounded reads (overview and relations) are fetched on mount.
  The unbounded terms -- messages, dictionary and state -- can be arbitrarily
  large even truncated, so each is gated behind an explicit fetch button.
  Every section keeps its own timeout and fetch time, and fetched data stays
  assigned across tab switches. `Query` owns the data loading; this module
  owns the async lifecycle and events.
  """

  use VoyagerWeb, :live_view

  import VoyagerWeb.Components.DetailsPanelComponents,
    only: [overview: 1, memory_and_garbage_collection: 1, section: 1]

  import VoyagerWeb.Components.ProcessInfoComponents
  import VoyagerWeb.Components.TermComponents

  alias Phoenix.LiveView.AsyncResult
  alias VoyagerWeb.Formatters
  alias VoyagerWeb.Hooks.TermTreeHook
  alias VoyagerWeb.ProcessInfoLive.Query

  require Logger

  on_mount TermTreeHook

  @tabs ~w(overview state messages dictionary relations)a
  @sections ~w(info relations state messages dictionary)a

  @impl true
  def mount(%{"pid" => pid_string}, _session, socket) do
    socket
    |> assign(:active_nav, :processes)
    |> assign(:pid_string, pid_string)
    |> assign(:pid, nil)
    |> assign(:tab, :overview)
    |> assign(:info, AsyncResult.loading())
    |> assign(:relations, AsyncResult.loading())
    |> assign(:messages, nil)
    |> assign(:dictionary, nil)
    |> assign(:state, nil)
    |> assign(:timeouts, Map.new(@sections, &{&1, Query.default_timeout()}))
    |> assign(:fetched_at, %{})
    |> assign(:last_updated, nil)
    |> resolve_pid(pid_string)
    |> ok()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto flex max-w-screen-2xl flex-col gap-4 p-6 sm:p-8">
      <.node_header
        node_name={@session.node_name}
        last_updated={@last_updated}
        waiting_message="waiting for first fetch…"
        class="mb-0"
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
        </:actions>
      </.node_header>

      <div class="flex flex-col gap-1">
        <.link
          id="back-to-processes"
          navigate={~p"/node/#{@session.node_name}/processes"}
          class="btn btn-ghost btn-sm w-max gap-2"
        >
          <.icon name="icon-arrow-left" class="size-4" /> All Processes
        </.link>
        <h2 class="text-base-content text-sm font-semibold leading-none">
          Process Info
          <span class="font-mono text-base-content/70 ml-1 text-xs font-normal">
            {@pid_string}
          </span>
        </h2>
      </div>

      <div id="process-info-tabs" class="tabs tabs-lift">
        <.tab_button tab={:overview} active={@tab} label="Overview" />
        <.tab_panel
          id="panel-overview"
          section={:info}
          fetched_at={@fetched_at[:info]}
          timeout={@timeouts.info}
          loading?={loading?(@info)}
          disabled={is_nil(@pid)}
        >
          <div class="grid grid-cols-1 items-start gap-x-8 gap-y-5 lg:grid-cols-2">
            <.overview info={@info} />
            <.memory_and_garbage_collection info={@info} />
          </div>
        </.tab_panel>

        <.tab_button tab={:state} active={@tab} label="State" />
        <.tab_panel
          id="panel-state"
          section={:state}
          fetched_at={@fetched_at[:state]}
          timeout={@timeouts.state}
          loading?={loading?(@state)}
          disabled={is_nil(@pid)}
        >
          <.section title="State">
            <.term_section
              :let={state}
              id="process-state"
              result={@state}
              placeholder="Calls :sys.get_state on the remote node. A busy process or one that does not handle system messages will time out."
            >
              <.term_inspector
                id="process-state"
                term={state.term}
                state={@term_states["process-state"]}
                truncated?={state.truncated?}
                class="overflow-x-auto"
              />
            </.term_section>
          </.section>
        </.tab_panel>

        <.tab_button tab={:messages} active={@tab} label="Messages" />
        <.tab_panel
          id="panel-messages"
          section={:messages}
          fetched_at={@fetched_at[:messages]}
          timeout={@timeouts.messages}
          loading?={loading?(@messages)}
          disabled={is_nil(@pid)}
        >
          <.section title="Messages" muted={queue_len_label(@info)}>
            <.term_section
              :let={messages}
              id="process-messages"
              result={@messages}
              placeholder="Copies the mailbox on the remote node before truncating, so a huge mailbox is expensive to read."
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
            </.term_section>
          </.section>
        </.tab_panel>

        <.tab_button tab={:dictionary} active={@tab} label="Dictionary" />
        <.tab_panel
          id="panel-dictionary"
          section={:dictionary}
          fetched_at={@fetched_at[:dictionary]}
          timeout={@timeouts.dictionary}
          loading?={loading?(@dictionary)}
          disabled={is_nil(@pid)}
        >
          <.section title="Dictionary" muted={bounded_count(@dictionary)}>
            <.term_section
              :let={dictionary}
              id="process-dictionary"
              result={@dictionary}
              placeholder="The process dictionary holds arbitrary user terms and can be large; it is truncated on the remote node."
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
            </.term_section>
          </.section>
        </.tab_panel>

        <.tab_button
          tab={:relations}
          active={@tab}
          label="Relations"
          tooltip="Links, Monitors and Monitored by"
        />
        <.tab_panel
          id="panel-relations"
          section={:relations}
          fetched_at={@fetched_at[:relations]}
          timeout={@timeouts.relations}
          loading?={loading?(@relations)}
          disabled={is_nil(@pid)}
        >
          <.async_result :let={relations} assign={@relations}>
            <:loading>
              <div class="grid grid-cols-1 gap-6 md:grid-cols-3">
                <.section :for={title <- ["Links", "Monitors", "Monitored by"]} title={title}>
                  <div class="flex flex-wrap gap-1.5">
                    <div :for={_ <- 1..3} class="skeleton h-6 w-16 rounded" />
                  </div>
                </.section>
              </div>
            </:loading>
            <:failed :let={reason}>
              <.section title="Links">
                <.fetch_alert id="process-relations-error" message={error_message(reason)} />
              </.section>
            </:failed>
            <div class="grid grid-cols-1 gap-6 md:grid-cols-3">
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
                  node_name={@session.node_name}
                  remote_node={@session.node}
                />
              </.section>
            </div>
          </.async_result>
        </.tab_panel>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("set-tab", %{"tab" => tab}, socket) do
    case Enum.find(@tabs, &(to_string(&1) == tab)) do
      nil -> noreply(socket)
      tab -> socket |> assign(:tab, tab) |> noreply()
    end
  end

  def handle_event("set-timeout", %{"section" => section, "timeout" => timeout}, socket) do
    with name when not is_nil(name) <- section_atom(section),
         timeout when not is_nil(timeout) <- parse_timeout(timeout) do
      socket
      |> assign(:timeouts, Map.put(socket.assigns.timeouts, name, timeout))
      |> noreply()
    else
      _ -> noreply(socket)
    end
  end

  def handle_event("fetch-" <> section, _params, %{assigns: %{pid: pid}} = socket)
      when is_pid(pid) do
    case section_atom(section) do
      nil -> noreply(socket)
      name -> socket |> fetch(name) |> noreply()
    end
  end

  # Buttons are disabled until the pid resolves; a click can still race that.
  def handle_event("fetch-" <> _section, _params, socket), do: noreply(socket)

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

  def handle_async(name, {:ok, {:ok, value}}, socket) when name in @sections do
    now = DateTime.utc_now()

    socket
    |> assign(name, AsyncResult.ok(socket.assigns[name], value))
    |> seed_terms(name, value)
    |> assign(:fetched_at, Map.put(socket.assigns.fetched_at, name, now))
    |> assign(:last_updated, now)
    |> noreply()
  end

  def handle_async(name, result, socket) when name in @sections do
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
    info: &Query.overview/3,
    relations: &Query.relations/3,
    messages: &Query.messages/3,
    dictionary: &Query.dictionary/3,
    state: &Query.state/3
  }

  defp fetch(socket, name) do
    %{pid: pid, session: %{node: node}, timeouts: timeouts} = socket.assigns
    query = Map.fetch!(@queries, name)
    timeout = Map.fetch!(timeouts, name)

    socket
    |> cancel_async(name, {:shutdown, :cancel})
    |> assign(name, mark_loading(socket.assigns[name]))
    |> start_async(name, fn -> query.(node, pid, timeout) end)
  end

  defp mark_loading(nil), do: AsyncResult.loading()
  defp mark_loading(%AsyncResult{} = result), do: AsyncResult.loading(result)

  defp section_atom(section), do: Enum.find(@sections, &(to_string(&1) == section))

  defp parse_timeout(value) when is_binary(value) do
    {min_ms, max_ms} = timeout_bounds()

    case Integer.parse(value) do
      {ms, ""} -> ms |> max(min_ms) |> min(max_ms)
      _ -> nil
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

  defp queue_len_label(%AsyncResult{ok?: true, result: %{message_queue_len: len}}),
    do: "(#{Formatters.format_integer(len)} in queue)"

  defp queue_len_label(_info), do: nil
end
