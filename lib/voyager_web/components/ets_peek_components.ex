defmodule VoyagerWeb.Components.EtsPeekComponents do
  @moduledoc """
  The ETS contents panel: the gated fetch controls, the truncation notice and
  the record list.

  Records are rendered by the shared term inspector, so this module holds no
  term rendering of its own.
  """

  use VoyagerWeb, :component

  alias VoyagerWeb.Components.TermComponents
  alias VoyagerWeb.Formatters
  alias VoyagerWeb.FormSchemas.EtsPeekControls
  alias VoyagerWeb.TermTree.State

  attr :table_name, :string, required: true
  attr :node_name, :string, required: true
  attr :info, :map, default: nil

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

      <div :if={@info} class="flex flex-wrap items-center gap-1">
        <span class="badge badge-sm badge-ghost font-mono">{@info.type}</span>
        <span class={["badge badge-sm font-mono", protection_class(@info.protection)]}>
          {@info.protection}
        </span>
        <span id="ets-keypos-badge" class="badge badge-sm badge-ghost font-mono">
          keypos {@info.keypos}
        </span>
        <span class="badge badge-sm badge-ghost font-mono">
          {Formatters.format_integer(@info.size)} records
        </span>
        <span class="badge badge-sm badge-ghost font-mono">
          {Formatters.format_bytes(@info.memory)}
        </span>
      </div>
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
              Chunk size
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

        <p :if={@form[:timeout].errors != []} class="font-mono text-error text-xs">
          {@form[:timeout].errors |> Enum.map_join(", ", &translate_error/1)}
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
        Records are shortened on the node before transfer — 512 B per binary, 50 items per
        collection, 5 levels deep. Paging is best-effort: the table can change between chunks.
      </span>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :records, :list, required: true
  attr :term_states, :map, required: true
  attr :offset, :integer, default: 0

  def records(assigns) do
    ~H"""
    <ol id={@id} class="flex flex-col gap-2">
      <li
        :for={{record, index} <- Enum.with_index(@records)}
        id={"#{@id}-#{@offset + index}"}
        class="border-base-300 bg-base-100 flex items-start gap-3 rounded-lg border p-3"
      >
        <span class="text-base-content/50 font-mono shrink-0 pt-0.5 text-xs tabular-nums">
          {@offset + index + 1}
        </span>

        <TermComponents.term_inspector
          id={record_inspector_id(@id, @offset + index)}
          term={record}
          state={@term_states[record_inspector_id(@id, @offset + index)] || %State{}}
          class="min-w-0 flex-1 overflow-x-auto"
        />

        <.copy_button
          id={"#{@id}-#{@offset + index}-copy"}
          target={"##{record_inspector_id(@id, @offset + index)}"}
          label="Copy record"
          icon_only
          size={:sm}
          class="text-base-content/60 shrink-0 hover:text-primary"
        />
      </li>
    </ol>
    """
  end

  @spec record_inspector_id(String.t(), non_neg_integer()) :: String.t()
  def record_inspector_id(prefix, index), do: "#{prefix}-#{index}-term"

  defp protection_class(:private), do: "badge-warning"
  defp protection_class(:protected), do: "badge-ghost"
  defp protection_class(_public), do: "badge-ghost"
end
