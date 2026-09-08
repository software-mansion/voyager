defmodule VoyagerWeb.ProcessInfoLive do
  @moduledoc """
  Shows a single process on the connected node, one tab per section.

  The cheap, size-bounded reads (overview and relations) are fetched on mount.
  The unbounded terms -- messages, dictionary and state -- can be arbitrarily
  large even truncated, so each is fetched only when its tab is first opened
  or its fetch button is pressed, never behind the user's back. Every section
  keeps its own timeout and fetch time, and fetched data stays assigned across
  tab switches. `Query` owns the data loading; this module owns the async
  lifecycle and events.
  """

  use VoyagerWeb, :live_view

  import VoyagerWeb.Components.DetailsPanelComponents,
    only: [overview: 1, memory_and_garbage_collection: 1, section: 1]

  import VoyagerWeb.Components.ProcessInfoComponents

  alias Phoenix.LiveView.AsyncResult
  alias VoyagerWeb.Formatters
  alias VoyagerWeb.Hooks.TermTreeHook
  alias VoyagerWeb.ProcessInfoLive.Query

  require Logger

  on_mount TermTreeHook

  @tabs ~w(overview state messages dictionary relations)a
  @sections ~w(info relations state messages dictionary)a
  @budget_sections ~w(state messages dictionary)a
  @limit_sections ~w(relations messages dictionary)a

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
    |> assign(:budgets, Map.new(@budget_sections, &{&1, Query.default_budget()}))
    |> assign(:limits, Query.default_limits())
    |> assign(:fetched_at, %{})
    |> assign(:settings_restored?, false)
    |> resolve_pid(pid_string)
    |> ok()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="process-info-page"
      phx-hook="TableSettings"
      data-settings-key="process-info"
      class="mx-auto flex h-full w-full max-w-screen-2xl flex-col gap-4 overflow-hidden p-6 sm:p-8"
    >
      <.node_header node_name={@session.node_name} waiting_message={nil} class="mb-0">
        <:actions>
          <div class="flex flex-col items-end gap-0.5">
            <.tooltip id="process-info-pid-tip" position="bottom" interactive tip_class="font-mono">
              <h2
                id="process-info-pid"
                class="text-base-content font-mono flex items-center gap-2 text-2xl font-bold tracking-tight"
              >
                <span class="bg-primary h-2 w-2 rounded-full" />
                {@pid_string}
              </h2>
              <:content>
                <div class="flex items-center gap-1">
                  <span id="process-info-pid-text">{@pid_string}</span>
                  <.copy_button
                    id="process-info-pid-copy"
                    target="#process-info-pid-text"
                    icon_only
                    label="Copy PID"
                    class="btn-xs text-base-content/50 shrink-0 hover:text-base-content"
                  />
                </div>
              </:content>
            </.tooltip>
            <.tooltip
              :if={registered_name(@info)}
              id="process-info-name-tip"
              position="bottom"
              interactive
              tip_class="font-mono"
            >
              <span id="process-info-name" class="font-mono text-base-content/70 text-sm">
                {registered_name(@info)}
              </span>
              <:content>
                <div class="flex items-center gap-1">
                  <span id="process-info-name-text">{registered_name(@info)}</span>
                  <.copy_button
                    id="process-info-name-copy"
                    target="#process-info-name-text"
                    icon_only
                    label="Copy registered name"
                    class="btn-xs text-base-content/50 shrink-0 hover:text-base-content"
                  />
                </div>
              </:content>
            </.tooltip>
          </div>
        </:actions>
      </.node_header>

      <.link
        id="back-to-processes"
        navigate={keep_sidebar(~p"/node/#{@session.node_name}/processes", @current_url)}
        class="btn btn-ghost btn-sm w-max gap-2"
      >
        <.icon name="icon-arrow-left" class="size-4" /> All Processes
      </.link>

      <div class="flex min-h-0 flex-1 flex-col">
        <div id="process-info-tabs" role="tablist" class="tabs tabs-lift">
          <.tab_button tab={:overview} active={@tab} label="Overview" />
          <.tab_button tab={:state} active={@tab} label="State" />
          <.tab_button tab={:messages} active={@tab} label="Messages" />
          <.tab_button tab={:dictionary} active={@tab} label="Dictionary" />
          <.tab_button
            tab={:relations}
            active={@tab}
            label="Relations"
            tooltip="Links, Monitors and Monitored by"
          />
        </div>

        <.tab_panel
          id="panel-overview"
          section={:info}
          active={@tab == :overview}
          fetched_at={@fetched_at[:info][:at]}
          took_ms={@fetched_at[:info][:took_ms]}
          timeout={@timeouts.info}
          loading?={loading?(@info)}
          disabled={is_nil(@pid)}
        >
          <div class="grid grid-cols-1 items-start gap-y-5 lg:divide-base-300 lg:grid-cols-2 lg:divide-x">
            <div class="lg:pr-8">
              <.overview info={@info} size={:sm} pid_href={pid_href(@session, @current_url)} />
            </div>
            <div class="lg:pl-8">
              <.memory_and_garbage_collection info={@info} size={:sm} />
            </div>
          </div>
        </.tab_panel>

        <.tab_panel
          id="panel-state"
          section={:state}
          active={@tab == :state}
          fetched_at={@fetched_at[:state][:at]}
          took_ms={@fetched_at[:state][:took_ms]}
          timeout={@timeouts.state}
          budget={@budgets.state}
          loading?={loading?(@state)}
          disabled={is_nil(@pid)}
          title="State"
          help="Calls :sys.get_state on the remote node. A busy process or one that does not handle system messages will time out."
        >
          <.term_section :let={state} id="process-state" result={@state}>
            <.copyable_term
              id="process-state"
              term={state.term}
              state={@term_states["process-state"]}
              label="Copy state"
              class="scrollbar-thin overflow-x-auto"
            />
          </.term_section>
        </.tab_panel>

        <.tab_panel
          id="panel-messages"
          section={:messages}
          active={@tab == :messages}
          fetched_at={@fetched_at[:messages][:at]}
          took_ms={@fetched_at[:messages][:took_ms]}
          timeout={@timeouts.messages}
          budget={@budgets.messages}
          limit={@limits.messages}
          loading?={loading?(@messages)}
          disabled={is_nil(@pid)}
          title="Messages"
          muted={queue_len_label(@messages)}
          help="Copies the mailbox on the remote node before truncating, so a huge mailbox is expensive to read."
        >
          <.term_section :let={messages} id="process-messages" result={@messages}>
            <p :if={messages.items == []} class="font-mono text-base-content/70 text-xs">
              Mailbox is empty.
            </p>
            <ol
              :if={messages.items != []}
              class="divide-base-content/10 m-0 flex list-none flex-col divide-y p-0"
            >
              <li :for={{message, index} <- Enum.with_index(messages.items)} class="py-2">
                <.copyable_term
                  id={"message-#{index}"}
                  term={message}
                  state={@term_states["message-#{index}"]}
                  label="Copy message"
                  class="scrollbar-thin overflow-x-auto"
                />
              </li>
            </ol>
            <.truncation_note :if={messages.truncated?} id="process-messages-truncated" />
          </.term_section>
        </.tab_panel>

        <.tab_panel
          id="panel-dictionary"
          section={:dictionary}
          active={@tab == :dictionary}
          fetched_at={@fetched_at[:dictionary][:at]}
          took_ms={@fetched_at[:dictionary][:took_ms]}
          timeout={@timeouts.dictionary}
          budget={@budgets.dictionary}
          limit={@limits.dictionary}
          loading?={loading?(@dictionary)}
          disabled={is_nil(@pid)}
          title="Dictionary"
          muted={bounded_count(@dictionary)}
          help="The process dictionary holds arbitrary user terms and can be large; it is truncated on the remote node."
        >
          <.term_section :let={dictionary} id="process-dictionary" result={@dictionary}>
            <p :if={dictionary.items == []} class="font-mono text-base-content/70 text-xs">
              Dictionary is empty.
            </p>
            <ol
              :if={dictionary.items != []}
              class="divide-base-content/10 m-0 flex list-none flex-col divide-y p-0"
            >
              <li
                :for={{{key, value}, index} <- Enum.with_index(dictionary.items)}
                class="flex items-baseline gap-6 py-2.5"
              >
                <.copyable_term
                  id={"dict-key-#{index}"}
                  term={key}
                  state={@term_states["dict-key-#{index}"]}
                  label="Copy key"
                  class="scrollbar-thin max-w-64 w-64 shrink-0 overflow-x-auto"
                />
                <.copyable_term
                  id={"dict-entry-#{index}"}
                  term={value}
                  state={@term_states["dict-entry-#{index}"]}
                  label="Copy value"
                  class="scrollbar-thin min-w-0 flex-1 overflow-x-auto"
                />
              </li>
            </ol>
            <.truncation_note :if={dictionary.truncated?} id="process-dictionary-truncated" />
          </.term_section>
        </.tab_panel>

        <.tab_panel
          id="panel-relations"
          section={:relations}
          active={@tab == :relations}
          fetched_at={@fetched_at[:relations][:at]}
          took_ms={@fetched_at[:relations][:took_ms]}
          timeout={@timeouts.relations}
          limit={@limits.relations}
          loading?={loading?(@relations)}
          disabled={is_nil(@pid)}
        >
          <.async_result :let={relations} assign={@relations}>
            <:loading>
              <div class="grid grid-cols-1 gap-y-6 md:divide-base-300 md:grid-cols-3 md:divide-x">
                <div
                  :for={title <- ["Links", "Monitors", "Monitored by"]}
                  class="md:px-6 md:first:pl-0 md:last:pr-0"
                >
                  <.section title={title}>
                    <div class="flex flex-wrap gap-1.5">
                      <div :for={_ <- 1..3} class="skeleton h-6 w-16 rounded" />
                    </div>
                  </.section>
                </div>
              </div>
            </:loading>
            <:failed :let={reason}>
              <.section title="Links">
                <.fetch_alert id="process-relations-error" message={error_message(reason)} />
              </.section>
            </:failed>
            <div class="grid grid-cols-1 gap-y-6 md:divide-base-300 md:grid-cols-3 md:divide-x">
              <div
                :for={
                  {title, id, bounded} <- [
                    {"Links", "process-links", relations.links},
                    {"Monitors", "process-monitors", relations.monitors},
                    {"Monitored by", "process-monitored-by", relations.monitored_by}
                  ]
                }
                class="md:px-6 md:first:pl-0 md:last:pr-0"
              >
                <.section title={title} muted={bounded_count(bounded)}>
                  <.identifier_chips
                    id={id}
                    items={bounded.items}
                    total={bounded.total}
                    node_name={@session.node_name}
                    remote_node={@session.node}
                    current_url={@current_url}
                  />
                </.section>
              </div>
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
      tab -> socket |> push_patch(to: tab_path(socket, tab)) |> noreply()
    end
  end

  def handle_event("set-timeout", %{"section" => section, "timeout" => timeout}, socket) do
    with name when not is_nil(name) <- section_atom(section),
         timeout when not is_nil(timeout) <- parse_bounded(timeout, timeout_bounds()) do
      socket
      |> assign(:timeouts, Map.put(socket.assigns.timeouts, name, timeout))
      |> store_settings()
      |> noreply()
    else
      _ -> noreply(socket)
    end
  end

  def handle_event("set-budget", %{"section" => section, "budget" => budget}, socket) do
    with name when name in @budget_sections <- section_atom(section),
         budget when not is_nil(budget) <- parse_bounded(budget, budget_bounds()) do
      socket
      |> assign(:budgets, Map.put(socket.assigns.budgets, name, budget))
      |> store_settings()
      |> noreply()
    else
      _ -> noreply(socket)
    end
  end

  def handle_event("set-limit", %{"section" => section, "limit" => limit}, socket) do
    with name when name in @limit_sections <- section_atom(section),
         limit when not is_nil(limit) <- parse_bounded(limit, limit_bounds()) do
      socket
      |> assign(:limits, Map.put(socket.assigns.limits, name, limit))
      |> store_settings()
      |> noreply()
    else
      _ -> noreply(socket)
    end
  end

  # The client's stored controls, empty when it has none. Only validated
  # values ever get stored, but the storage is still hand-editable.
  def handle_event("restore_settings", params, socket) when is_map(params) do
    socket
    |> restore_controls(:timeouts, params["timeouts"], timeout_bounds())
    |> restore_controls(:budgets, params["budgets"], budget_bounds())
    |> restore_controls(:limits, params["limits"], limit_bounds())
    |> settings_restored()
    |> noreply()
  end

  def handle_event("restore_settings", _params, socket) do
    socket |> settings_restored() |> noreply()
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
    |> maybe_start_fetching()
    |> noreply()
  end

  def handle_async(:pid, result, socket) do
    reason =
      case result do
        {:ok, {:error, reason}} -> reason
        {:exit, reason} -> reason
      end

    Logger.warning("Failed to resolve pid #{socket.assigns.pid_string}: #{inspect(reason)}")

    reason = if reason in [:timeout, :noconnection], do: reason, else: :invalid_pid

    socket |> redirect_fatal(reason) |> noreply()
  end

  def handle_async(_name, {:exit, {:shutdown, :cancel}}, socket), do: noreply(socket)

  def handle_async(name, {:ok, {:ok, value, took_ms}}, socket) when name in @sections do
    fetch = %{at: DateTime.utc_now(), took_ms: took_ms}

    socket
    |> assign(name, AsyncResult.ok(socket.assigns[name], value))
    |> seed_terms(name, value)
    |> assign(:fetched_at, Map.put(socket.assigns.fetched_at, name, fetch))
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
    |> apply_failure(name, reason)
    |> noreply()
  end

  # Like the process list, a transient failure flashes over data that is still
  # the last good answer; with nothing on screen it fails the section instead,
  # or the panel would sit on its skeleton behind a toast.
  defp apply_failure(socket, name, reason) when reason in [:timeout, :rate_limited] do
    case socket.assigns[name] do
      %AsyncResult{ok?: true} = result ->
        socket
        |> assign(name, %{result | loading: nil})
        |> put_flash(:error, error_message(reason))

      result ->
        assign(socket, name, AsyncResult.failed(result, reason))
    end
  end

  defp apply_failure(socket, _name, :dead), do: redirect_fatal(socket, :dead)

  defp apply_failure(socket, name, reason) do
    assign(socket, name, AsyncResult.failed(socket.assigns[name], reason))
  end

  # A pid that cannot be inspected at all leaves nothing to show; back to the
  # list with the reason as a flash.
  defp redirect_fatal(socket, reason) do
    path = ~p"/node/#{socket.assigns.session.node_name}/processes"

    socket
    |> put_flash(:error, error_message(reason))
    |> push_navigate(to: keep_sidebar(path, socket.assigns[:current_url]))
  end

  defp resolve_pid(socket, pid_string) do
    node = socket.assigns.session.node

    cond do
      not connected?(socket) ->
        socket

      not Query.valid_pid_string?(pid_string) ->
        redirect_fatal(socket, :invalid_pid)

      true ->
        start_async(socket, :pid, fn -> Query.resolve_pid(node, pid_string) end)
    end
  end

  # The first fetch waits for both the resolved pid and the client's stored
  # controls, so a stored limit/budget/timeout applies to the first load.
  defp maybe_start_fetching(socket) do
    if is_pid(socket.assigns.pid) and socket.assigns.settings_restored? do
      socket
      |> fetch(:info)
      |> fetch(:relations)
      |> maybe_autofetch(socket.assigns.tab)
    else
      socket
    end
  end

  defp settings_restored(socket) do
    socket
    |> assign(:settings_restored?, true)
    |> maybe_start_fetching()
  end

  @queries %{
    info: &Query.overview/3,
    relations: &Query.relations/4,
    messages: &Query.messages/5,
    dictionary: &Query.dictionary/5,
    state: &Query.state/4
  }

  # Argument order mirrors the service signatures: limit, then budget, then
  # timeout; a section without one of them simply skips that slot.
  defp fetch(socket, name) do
    %{pid: pid, session: %{node: node}} = socket.assigns
    %{timeouts: timeouts, budgets: budgets, limits: limits} = socket.assigns
    query = Map.fetch!(@queries, name)

    args =
      [node, pid] ++
        optional_arg(limits, name) ++
        optional_arg(budgets, name) ++
        [Map.fetch!(timeouts, name)]

    socket
    |> cancel_async(name, {:shutdown, :cancel})
    |> assign(name, mark_loading(socket.assigns[name]))
    |> start_async(name, fn -> apply(query, args) end)
  end

  defp optional_arg(map, name) do
    case map do
      %{^name => value} -> [value]
      %{} -> []
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = Enum.find(@tabs, &(to_string(&1) == params["tab"])) || :overview

    socket
    |> assign(:tab, tab)
    |> maybe_autofetch(tab)
    |> noreply()
  end

  defp tab_path(socket, tab) do
    %{session: session, pid_string: pid_string, current_url: current_url} = socket.assigns
    path = ~p"/node/#{session.node_name}/processes/#{pid_string}?tab=#{tab}"
    keep_sidebar(path, current_url)
  end

  # Opening a gated tab for the first time fetches it; data that is already
  # there (or in flight) is left alone.
  defp maybe_autofetch(socket, tab) when tab in [:state, :messages, :dictionary] do
    if is_nil(socket.assigns[tab]) and is_pid(socket.assigns.pid) do
      fetch(socket, tab)
    else
      socket
    end
  end

  defp maybe_autofetch(socket, _tab), do: socket

  defp mark_loading(nil), do: AsyncResult.loading()
  defp mark_loading(%AsyncResult{} = result), do: AsyncResult.loading(result)

  defp section_atom(section), do: Enum.find(@sections, &(to_string(&1) == section))

  defp registered_name(%AsyncResult{ok?: true, result: %{registered_name: name}})
       when not is_nil(name),
       do: inspect(name)

  defp registered_name(_info), do: nil

  defp store_settings(socket) do
    push_event(socket, "store-settings", %{
      settings: %{
        "timeouts" => socket.assigns.timeouts,
        "budgets" => socket.assigns.budgets,
        "limits" => socket.assigns.limits
      }
    })
  end

  defp restore_controls(socket, key, values, bounds) when is_map(values) do
    restored =
      Map.new(socket.assigns[key], fn {section, current} ->
        case parse_bounded(values[to_string(section)], bounds) do
          nil -> {section, current}
          value -> {section, value}
        end
      end)

    assign(socket, key, restored)
  end

  defp restore_controls(socket, _key, _values, _bounds), do: socket

  defp parse_bounded(value, bounds) when is_integer(value),
    do: value |> Integer.to_string() |> parse_bounded(bounds)

  defp parse_bounded(value, {lower, upper}) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n |> max(lower) |> clamp_upper(upper)
      _ -> nil
    end
  end

  defp parse_bounded(_value, _bounds), do: nil

  defp clamp_upper(n, nil), do: n
  defp clamp_upper(n, upper), do: min(n, upper)

  defp pid_href(session, current_url) do
    fn value ->
      if is_pid(value) and node(value) == session.node do
        path = ~p"/node/#{session.node_name}/processes/#{Formatters.format_pid(value)}"
        keep_sidebar(path, current_url)
      end
    end
  end

  defp seed_terms(socket, :state, %{term: term}),
    do: TermTreeHook.put_term(socket, "process-state", term)

  defp seed_terms(socket, :messages, %{items: items}),
    do: seed_term_list(socket, "message", items)

  # An entry the remote truncated down to a bare marker has no key half and is
  # seeded as a value only.
  defp seed_terms(socket, :dictionary, %{items: items}) do
    items
    |> Enum.with_index()
    |> Enum.reduce(socket, fn
      {{key, value}, index}, socket ->
        socket
        |> TermTreeHook.put_term("dict-key-#{index}", key)
        |> TermTreeHook.put_term("dict-entry-#{index}", value)

      {other, index}, socket ->
        TermTreeHook.put_term(socket, "dict-entry-#{index}", other)
    end)
  end

  defp seed_terms(socket, _name, _value), do: socket

  defp seed_term_list(socket, prefix, items) do
    items
    |> Enum.with_index()
    |> Enum.reduce(socket, fn {term, index}, socket ->
      TermTreeHook.put_term(socket, "#{prefix}-#{index}", term)
    end)
  end

  defp queue_len_label(%AsyncResult{ok?: true, result: %{total: total}}),
    do: "(#{Formatters.format_integer(total)} in queue)"

  defp queue_len_label(_messages), do: nil
end
