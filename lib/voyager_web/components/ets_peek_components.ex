defmodule VoyagerWeb.Components.EtsPeekComponents do
  @moduledoc """
  The ETS contents page: the table info panel, the gated fetch controls, the
  paginated record list and the lookup sidebar.
  """

  use VoyagerWeb, :component

  alias VoyagerWeb.Components.TermComponents
  alias VoyagerWeb.Formatters
  alias VoyagerWeb.FormSchemas.EtsLookupControls
  alias VoyagerWeb.FormSchemas.EtsPeekControls
  alias VoyagerWeb.TermTree.State

  @truncated :"$voyager_truncated"

  attr :table_name, :string, required: true
  attr :node_name, :string, required: true

  def header(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-3">
      <.link
        id="back-to-ets-tables"
        navigate={~p"/node/#{@node_name}"}
        class="btn btn-ghost btn-sm gap-2"
      >
        <.icon name="icon-arrow-left" class="size-4" /> Node
      </.link>

      <h1 id="ets-table-name" class="font-mono text-base-content truncate text-lg font-semibold">
        {@table_name}
      </h1>
    </div>
    """
  end

  attr :info, :map, required: true

  def info_panel(assigns) do
    ~H"""
    <dl
      id="ets-table-info"
      class="border-base-300 bg-base-100 grid grid-cols-2 gap-x-6 gap-y-3 rounded-lg border p-4 sm:grid-cols-3 lg:grid-cols-5"
    >
      <.info_item label="Type">
        <span class="badge badge-sm badge-ghost font-mono">{@info.type}</span>
      </.info_item>
      <.info_item label="Protection">
        <span class={["badge badge-sm font-mono", protection_class(@info.protection)]}>
          {@info.protection}
        </span>
      </.info_item>
      <.info_item id="ets-info-keypos" label="Key position">{@info.keypos}</.info_item>
      <.info_item label="Records">{Formatters.format_integer(@info.size)}</.info_item>
      <.info_item label="Memory">{Formatters.format_bytes(@info.memory)}</.info_item>
      <.info_item label="Owner">{inspect(@info.owner)}</.info_item>
      <.info_item label="Heir">
        {if @info.heir == :none, do: "none", else: inspect(@info.heir)}
      </.info_item>
      <.info_item label="Named table">{@info.named_table}</.info_item>
      <.info_item label="Compressed">{@info.compressed}</.info_item>
      <.info_item label="Read concurrency">{@info.read_concurrency}</.info_item>
      <.info_item label="Write concurrency">{@info.write_concurrency}</.info_item>
      <.info_item :if={Map.has_key?(@info, :decentralized_counters)} label="Decentralized counters">
        {@info.decentralized_counters}
      </.info_item>
    </dl>
    """
  end

  attr :label, :string, required: true
  attr :id, :string, default: nil
  slot :inner_block, required: true

  defp info_item(assigns) do
    ~H"""
    <div id={@id} class="flex min-w-0 flex-col gap-0.5">
      <dt class="text-base-content/60 text-xs">{@label}</dt>
      <dd class="font-mono text-base-content truncate text-xs">{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :loading?, :boolean, default: false
  attr :readable?, :boolean, default: true
  attr :fetched?, :boolean, default: false

  def controls(assigns) do
    ~H"""
    <.form for={@form} id="ets-peek-controls" phx-change="validate" class="flex flex-col gap-1">
      <fieldset
        disabled={@loading? or not @readable?}
        class={["contents", (@loading? or not @readable?) && "opacity-60"]}
      >
        <div class="flex flex-wrap items-end gap-3">
          <div class="flex flex-col gap-1">
            <label for={@form[:chunk_size].id} class="text-base-content/70 text-xs font-medium">
              Page size
            </label>
            <select
              id={@form[:chunk_size].id}
              name={@form[:chunk_size].name}
              class="select select-sm w-24"
            >
              <option
                :for={value <- EtsPeekControls.chunk_size_options()}
                value={value}
                selected={to_string(value) == to_string(@form[:chunk_size].value)}
              >
                {value}
              </option>
            </select>
          </div>

          <div class="flex flex-col gap-1">
            <label for={@form[:budget].id} class="text-base-content/70 text-xs font-medium">
              Budget per record
            </label>
            <input
              id={@form[:budget].id}
              type="number"
              name={@form[:budget].name}
              value={@form[:budget].value}
              min={elem(EtsPeekControls.budget_bounds(), 0)}
              max={elem(EtsPeekControls.budget_bounds(), 1)}
              step="100"
              inputmode="numeric"
              phx-debounce="500"
              class={[
                "input input-sm input-bordered no-spinner font-mono w-24",
                @form[:budget].errors != [] && "input-error"
              ]}
            />
          </div>

          <div class="flex flex-col gap-1">
            <label for={@form[:timeout].id} class="text-base-content/70 text-xs font-medium">
              Timeout (ms)
            </label>
            <input
              id={@form[:timeout].id}
              type="number"
              name={@form[:timeout].name}
              value={@form[:timeout].value}
              min={elem(EtsPeekControls.timeout_bounds(), 0)}
              max={elem(EtsPeekControls.timeout_bounds(), 1)}
              step="100"
              inputmode="numeric"
              phx-debounce="500"
              class={[
                "input input-sm input-bordered no-spinner font-mono w-24",
                @form[:timeout].errors != [] && "input-error"
              ]}
            />
          </div>

          <button
            id="ets-peek-fetch"
            type="button"
            phx-click="fetch"
            disabled={@loading? or not @readable?}
            class="btn btn-primary btn-sm gap-2"
          >
            <span :if={@loading?} class="loading loading-spinner loading-xs" />
            {if @fetched?, do: "Reload snapshot", else: "Fetch records"}
          </button>
        </div>

        <p
          :for={field <- [:budget, :timeout]}
          :if={@form[field].errors != []}
          class="font-mono text-error text-xs"
        >
          {@form[field].errors |> Enum.map_join(", ", &translate_error/1)}
        </p>
      </fieldset>
    </.form>
    """
  end

  def truncation_notice(assigns) do
    ~H"""
    <div id="ets-truncation-notice" role="note" class="alert alert-info text-xs">
      <.icon name="icon-info" class="size-4 shrink-0" />
      <span>
        Some records were shortened on the node to fit the term budget. Paging is
        best-effort: the table can change between pages.
      </span>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :records, :list, required: true
  attr :term_states, :map, required: true
  attr :open_rows, :any, required: true
  attr :offset, :integer, default: 0
  attr :lookupable?, :boolean, default: false
  attr :keypos, :integer, default: 1

  def records(assigns) do
    ~H"""
    <ol id={@id} class="flex flex-col gap-1">
      <li
        :for={{record, index} <- Enum.with_index(@records)}
        id={"#{@id}-#{index}"}
        class="border-base-300 bg-base-100 rounded-lg border"
      >
        <div class="flex items-center gap-2 px-3 py-2">
          <button
            id={"#{@id}-#{index}-toggle"}
            type="button"
            phx-click="toggle_row"
            phx-value-index={index}
            aria-expanded={to_string(row_open?(@open_rows, index))}
            class="flex min-w-0 flex-1 items-center gap-3 rounded text-left transition-colors hover:bg-base-200"
          >
            <.icon
              name="icon-chevron-right"
              class={[
                "text-base-content/50 size-3.5 shrink-0 transition-transform",
                row_open?(@open_rows, index) && "rotate-90"
              ]}
            />
            <span class="text-base-content/50 font-mono shrink-0 text-xs tabular-nums">
              {@offset + index + 1}
            </span>
            <span class="font-mono text-base-content min-w-0 flex-1 truncate text-xs">
              {preview(record)}
            </span>
          </button>

          <button
            :if={@lookupable? and lookup_key(record, @keypos) != :error}
            id={"#{@id}-#{index}-lookup"}
            type="button"
            phx-click="open_sidebar"
            phx-value-index={index}
            title="Look up this record"
            class="btn btn-ghost btn-xs text-base-content/60 shrink-0 gap-1 hover:text-primary"
          >
            <.icon name="icon-panel-left" class="size-3.5 -scale-x-100" /> Lookup
          </button>
        </div>

        <div :if={row_open?(@open_rows, index)} class="border-base-300 border-t px-3 py-2">
          <TermComponents.term_inspector
            id={record_inspector_id(@id, index)}
            term={record}
            state={@term_states[record_inspector_id(@id, index)] || %State{}}
            class="overflow-x-auto"
          />
        </div>
      </li>
    </ol>
    """
  end

  attr :page, :integer, required: true
  attr :has_next?, :boolean, required: true
  attr :loading?, :boolean, default: false

  def pagination(assigns) do
    ~H"""
    <nav id="ets-pagination" class="flex items-center gap-2" aria-label="Record pages">
      <button
        id="ets-page-prev"
        type="button"
        phx-click="prev_page"
        disabled={@page == 0 or @loading?}
        class="btn btn-outline btn-sm"
      >
        <.icon name="icon-arrow-left" class="size-4" /> Previous
      </button>
      <span id="ets-page-label" class="text-base-content/70 text-xs tabular-nums">
        Page {@page + 1}
      </span>
      <button
        id="ets-page-next"
        type="button"
        phx-click="next_page"
        disabled={not @has_next? or @loading?}
        class="btn btn-outline btn-sm"
      >
        Next <.icon name="icon-arrow-right" class="size-4" />
      </button>
    </nav>
    """
  end

  attr :key, :any, required: true
  attr :lookup, Phoenix.LiveView.AsyncResult, required: true
  attr :form, Phoenix.HTML.Form, required: true
  attr :term_states, :map, required: true
  attr :error_message, :string, default: nil

  def sidebar(assigns) do
    ~H"""
    <aside
      id="ets-lookup-sidebar"
      class="border-base-300 bg-base-100 flex w-full shrink-0 flex-col gap-4 overflow-y-auto border-l p-4 lg:w-96"
    >
      <div class="flex items-center justify-between gap-2">
        <h2 class="text-base-content text-sm font-semibold">Record lookup</h2>
        <button
          id="ets-sidebar-close"
          type="button"
          phx-click="close_sidebar"
          aria-label="Close sidebar"
          class="btn btn-ghost btn-xs"
        >
          <.icon name="icon-x" class="size-4" />
        </button>
      </div>

      <div class="flex min-w-0 flex-col gap-0.5">
        <span class="text-base-content/60 text-xs">Key</span>
        <span id="ets-sidebar-key" class="font-mono text-base-content break-all text-xs">
          {inspect(@key)}
        </span>
      </div>

      <.form
        for={@form}
        id="ets-lookup-controls"
        phx-change="validate_lookup"
        class="flex flex-col gap-1"
      >
        <div class="flex flex-wrap items-end gap-3">
          <div class="flex flex-col gap-1">
            <label for={@form[:budget].id} class="text-base-content/70 text-xs font-medium">
              Term budget
            </label>
            <input
              id={@form[:budget].id}
              type="number"
              name={@form[:budget].name}
              value={@form[:budget].value}
              min={elem(EtsLookupControls.budget_bounds(), 0)}
              max={elem(EtsLookupControls.budget_bounds(), 1)}
              step="100"
              inputmode="numeric"
              phx-debounce="500"
              class={[
                "input input-sm input-bordered no-spinner font-mono w-24",
                @form[:budget].errors != [] && "input-error"
              ]}
            />
          </div>

          <div class="flex flex-col gap-1">
            <label for={@form[:timeout].id} class="text-base-content/70 text-xs font-medium">
              Timeout (ms)
            </label>
            <input
              id={@form[:timeout].id}
              type="number"
              name={@form[:timeout].name}
              value={@form[:timeout].value}
              min={elem(EtsLookupControls.timeout_bounds(), 0)}
              max={elem(EtsLookupControls.timeout_bounds(), 1)}
              step="100"
              inputmode="numeric"
              phx-debounce="500"
              class={[
                "input input-sm input-bordered no-spinner font-mono w-24",
                @form[:timeout].errors != [] && "input-error"
              ]}
            />
          </div>

          <button
            id="ets-lookup-refetch"
            type="button"
            phx-click="refetch_lookup"
            disabled={@lookup.loading != nil}
            class="btn btn-primary btn-sm gap-2"
          >
            <span :if={@lookup.loading != nil} class="loading loading-spinner loading-xs" /> Refetch
          </button>
        </div>

        <p
          :for={field <- [:budget, :timeout]}
          :if={@form[field].errors != []}
          class="font-mono text-error text-xs"
        >
          {@form[field].errors |> Enum.map_join(", ", &translate_error/1)}
        </p>
      </.form>

      <.async_result :let={chunk} assign={@lookup}>
        <:loading>
          <.loading_state id="ets-lookup-loading" message="Looking up record…" />
        </:loading>
        <:failed>
          <.error_state id="ets-lookup-error" message={@error_message} />
        </:failed>

        <p :if={chunk.records == []} id="ets-lookup-empty" class="text-base-content/70 text-sm">
          No record with this key. It may have been deleted.
        </p>

        <div
          :for={{record, index} <- Enum.with_index(chunk.records)}
          id={"ets-lookup-record-#{index}"}
          class="border-base-300 rounded-lg border p-3"
        >
          <TermComponents.term_inspector
            id={lookup_inspector_id(index)}
            term={record}
            state={@term_states[lookup_inspector_id(index)] || %State{}}
            class="overflow-x-auto"
          />
        </div>

        <p :if={chunk.truncated?} id="ets-lookup-truncated" class="text-base-content/50 text-xs">
          Shortened to fit the term budget — raise it and refetch to see more.
        </p>
      </.async_result>
    </aside>
    """
  end

  @spec record_inspector_id(String.t(), non_neg_integer()) :: String.t()
  def record_inspector_id(prefix, index), do: "#{prefix}-#{index}-term"

  @spec lookup_inspector_id(non_neg_integer()) :: String.t()
  def lookup_inspector_id(index), do: "ets-lookup-#{index}-term"

  @doc """
  The lookup key at `keypos`, or `:error` when the record is not a plain tuple
  or the key is not a type `Voyager.Services.Ets.Fetch.lookup/5` accepts —
  a truncated key would look up a record that does not exist.
  """
  @spec lookup_key(term(), pos_integer()) :: {:ok, term()} | :error
  def lookup_key(record, keypos)
      when is_tuple(record) and tuple_size(record) >= keypos and
             elem(record, 0) != @truncated do
    case elem(record, keypos - 1) do
      key when is_atom(key) or is_integer(key) -> {:ok, key}
      key when is_binary(key) -> {:ok, key}
      _key -> :error
    end
  end

  def lookup_key(_record, _keypos), do: :error

  defp row_open?(open_rows, index), do: MapSet.member?(open_rows, index)

  defp preview(record) do
    record
    |> strip_markers()
    |> inspect(limit: 20, printable_limit: 128, width: :infinity)
  rescue
    _e -> inspect(record, limit: 20, printable_limit: 128, width: :infinity)
  end

  defp strip_markers(@truncated), do: :...
  defp strip_markers({@truncated, :depth}), do: :...
  defp strip_markers({@truncated, :binary, prefix, _size}), do: prefix <> "…"

  defp strip_markers({@truncated, :map, pairs, _omitted}) when is_list(pairs) do
    Map.new(pairs, fn {k, v} -> {strip_markers(k), strip_markers(v)} end)
  end

  defp strip_markers({@truncated, :tuple, elements, _omitted}) when is_list(elements) do
    List.to_tuple(Enum.map(elements, &strip_markers/1) ++ [:...])
  end

  defp strip_markers({@truncated, :list, elements, _omitted}) when is_list(elements) do
    Enum.map(elements, &strip_markers/1) ++ [:...]
  end

  defp strip_markers(list) when is_list(list), do: Enum.map(list, &strip_markers/1)

  defp strip_markers(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.map(&strip_markers/1) |> List.to_tuple()
  end

  defp strip_markers(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} -> {strip_markers(k), strip_markers(v)} end)
  end

  defp strip_markers(other), do: other

  defp protection_class(:private), do: "badge-warning"
  defp protection_class(_other), do: "badge-ghost"
end
