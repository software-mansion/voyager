defmodule VoyagerWeb.TracingSessionLive.ConfigModal do
  @moduledoc false

  use VoyagerWeb, :html

  alias Phoenix.HTML.Form

  @processes [
    {"all", "All processes", "Every process, including ones spawned during the run"},
    {"existing", "Existing processes", "Processes alive when the run starts"},
    {"new", "New processes", "Processes spawned after the run starts"},
    {"pids", "Selected processes", "Only the pids you list"}
  ]

  attr :form, Phoenix.HTML.Form, required: true
  attr :error, :string, default: nil
  attr :pending?, :boolean, required: true
  attr :on_change, :string, required: true
  attr :on_submit, :string, required: true
  attr :on_cancel, :string, required: true

  def config_modal(assigns) do
    pids = assigns.form[:pids]

    assigns =
      assign(assigns,
        processes: @processes,
        selected: to_string(assigns.form[:processes].value),
        # "Selected processes" reveals an empty pids input; its error waits for typing or a submit.
        pids: if(used_input?(pids), do: pids, else: %{pids | errors: []}),
        return_trace?: Form.normalize_value("checkbox", assigns.form[:return_trace].value)
      )

    ~H"""
    <div
      id="config-modal"
      role="dialog"
      aria-modal="true"
      aria-labelledby="config-modal-title"
      phx-window-keydown={@on_cancel}
      phx-key="Escape"
      class="modal modal-middle modal-open"
    >
      <.focus_wrap
        id="config-modal-box"
        phx-mounted={JS.focus(to: "#config_module")}
        class="modal-box border-base-300 flex max-w-3xl flex-col border p-0 shadow-2xl"
      >
        <.form
          for={@form}
          id="config-form"
          phx-change={@on_change}
          phx-submit={@on_submit}
          class="flex min-h-0 flex-1 flex-col"
        >
          <div class="border-base-200 flex items-center justify-between gap-4 border-b py-4 pr-5 pl-8">
            <h2 id="config-modal-title" class="text-lg font-semibold tracking-tight">
              Session parameters
            </h2>
            <button
              type="button"
              id="config-close"
              phx-click={@on_cancel}
              title="Close"
              aria-label="Close session parameters"
              class="btn btn-ghost btn-square toolbar-btn text-base-content/60 hover:text-base-content"
            >
              <.icon name="icon-x" class="toolbar-icon" />
            </button>
          </div>

          <div class="min-h-0 flex-1 space-y-10 overflow-y-auto px-8 py-7">
            <section>
              <.section_title>What to trace</.section_title>
              <div class="grid grid-cols-5 gap-4">
                <.field
                  field={@form[:module]}
                  label="Module"
                  placeholder="MyApp.Repo or :lists"
                  class="col-span-2"
                />
                <.field
                  field={@form[:function]}
                  label="Function"
                  placeholder="any"
                  class="col-span-2"
                />
                <.field field={@form[:arity]} label="Arity" type="number" placeholder="any" min="0" />
              </div>
            </section>

            <section>
              <.section_title>Where</.section_title>
              <div class="grid grid-cols-2 gap-3">
                <label
                  :for={{value, label, hint} <- @processes}
                  for={"config_processes_#{value}"}
                  class={[
                    "border-base-300 rounded-box flex cursor-pointer gap-3 border p-4",
                    @selected == value && "border-primary bg-primary/5"
                  ]}
                >
                  <input
                    type="radio"
                    id={"config_processes_#{value}"}
                    name={@form[:processes].name}
                    value={value}
                    checked={@selected == value}
                    class="radio radio-primary radio-sm mt-0.5"
                  />
                  <span>
                    <span class="block text-sm font-medium">{label}</span>
                    <span class="text-base-content/60 block text-xs">{hint}</span>
                  </span>
                </label>
              </div>
              <div class={["mt-4", @selected != "pids" && "hidden"]}>
                <.field field={@pids} label="Pids" placeholder="<0.123.0>, <0.456.0>" />
              </div>
            </section>

            <section>
              <.section_title>Capture</.section_title>
              <div class="border-base-300 divide-base-300 rounded-box divide-y border">
                <.capture_row title="Calls record" hint="Arguments cost more than arity.">
                  <.segmented
                    name={@form[:capture].name}
                    value={@form[:capture].value}
                    size="sm"
                    options={[
                      %{value: "arity", label: "Arity", id: "config_capture_arity"},
                      %{value: "args", label: "Arguments", id: "config_capture_args"}
                    ]}
                  />
                </.capture_row>
                <.capture_row
                  title="Which calls"
                  hint="Global traces calls from other modules. Local also traces calls from inside the module."
                >
                  <.segmented
                    name={@form[:scope].name}
                    value={@form[:scope].value}
                    size="sm"
                    options={[
                      %{value: "global", label: "Global", id: "config_scope_global"},
                      %{value: "local", label: "Local", id: "config_scope_local"}
                    ]}
                  />
                </.capture_row>
                <.capture_row
                  title="Return values"
                  hint="Also traces returns and exceptions, which gives call durations."
                >
                  <input type="hidden" name={@form[:return_trace].name} value="false" />
                  <input
                    type="checkbox"
                    id={@form[:return_trace].id}
                    name={@form[:return_trace].name}
                    value="true"
                    checked={@return_trace?}
                    aria-label="Return values"
                    class="toggle toggle-primary"
                  />
                </.capture_row>
              </div>
            </section>

            <section>
              <.section_title hint="At least one is required">Stop after</.section_title>
              <div class="grid grid-cols-3 gap-4">
                <.field field={@form[:max_events]} label="Max events" type="number" min="1" />
                <.field field={@form[:max_rate]} label="Max events / s" type="number" min="1" />
                <div>
                  <label for={@form[:max_time].id} class="mb-1 block text-sm font-medium">
                    Max time
                  </label>
                  <.input_with_units
                    field={@form[:max_time]}
                    unit_field={@form[:max_time_unit]}
                    units={["s", "ms"]}
                    min="1"
                  />
                </div>
              </div>
            </section>

            <section>
              <.section_title>Advanced</.section_title>
              <div class="grid grid-cols-2 gap-4">
                <div>
                  <div class="mb-1 flex items-center gap-1.5">
                    <label for={@form[:budget].id} class="text-sm font-medium">
                      Max size per captured term
                    </label>
                    <.tooltip id="config-budget-tip" position="top" tip_class="max-w-sm">
                      <button
                        type="button"
                        class="text-base-content/60 hover:text-base-content"
                        aria-label="About the term size limit"
                      >
                        <.icon name="icon-circle-help" class="size-3.5" />
                      </button>
                      <:content>
                        <div class="space-y-1.5 text-left text-xs leading-relaxed">
                          <p>
                            Caps each captured term on its own: a call's arguments, a return value, an exception.
                          </p>
                          <p>
                            Atoms, small integers, list cells, tuples and map entries cost 1 each. Strings and binaries cost 1 per byte, so a long binary is cut at the limit.
                          </p>
                          <p>
                            What doesn't fit is replaced with a marker, and the event shows as truncated in the log.
                          </p>
                          <p>
                            It only matters when arguments or return values are captured. A higher limit costs the traced node more memory and network. Maximum 100,000.
                          </p>
                        </div>
                      </:content>
                    </.tooltip>
                  </div>
                  <.input field={@form[:budget]} type="number" min="0" />
                </div>
                <div>
                  <label
                    for="config-match-spec"
                    class="mb-1 flex items-center gap-1.5 text-sm font-medium"
                  >
                    Match spec <span class="badge badge-ghost badge-xs">Coming soon</span>
                  </label>
                  <input
                    id="config-match-spec"
                    disabled
                    placeholder="fn [a, _] when a > 10 -> :return_trace end"
                    class="input font-mono w-full"
                  />
                </div>
              </div>
            </section>
          </div>

          <div class="border-base-200 flex items-center gap-2 border-t px-8 py-4">
            <p :if={@error} id="config-error" class="text-error mr-auto text-sm">{@error}</p>
            <button
              type="button"
              id="config-cancel"
              phx-click={@on_cancel}
              class="btn btn-ghost ml-auto"
            >
              Cancel
            </button>
            <button
              type="submit"
              id="config-save"
              name="action"
              value="save"
              disabled={@pending?}
              class="btn"
            >
              Save
            </button>
            <button
              type="submit"
              id="config-start"
              name="action"
              value="start"
              disabled={@pending?}
              class="btn btn-primary"
            >
              <.icon name="icon-play" class="size-3.5" /> Save and start
            </button>
          </div>
        </.form>
      </.focus_wrap>

      <button
        type="button"
        id="config-backdrop"
        phx-click={@on_cancel}
        class="modal-backdrop"
        aria-label="Close session parameters"
      >
        Close
      </button>
    </div>
    """
  end

  attr :hint, :string, default: nil
  slot :inner_block, required: true

  defp section_title(assigns) do
    ~H"""
    <div class="mb-2 flex items-baseline gap-2">
      <h3 class="font-mono tracking-label text-base-content/60 text-xs font-semibold uppercase">
        {render_slot(@inner_block)}
      </h3>
      <span :if={@hint} class="text-base-content/60 text-xs">{@hint}</span>
    </div>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :type, :string, default: "text"
  attr :class, :string, default: nil
  attr :rest, :global, include: ~w(min placeholder)

  defp field(assigns) do
    ~H"""
    <div class={@class}>
      <label for={@field.id} class="mb-1 block text-sm font-medium">{@label}</label>
      <.input field={@field} type={@type} class={@type == "text" && "font-mono"} {@rest} />
    </div>
    """
  end

  attr :title, :string, required: true
  attr :hint, :string, required: true
  slot :inner_block, required: true

  defp capture_row(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-6 px-5 py-4">
      <div>
        <div class="text-sm font-medium">{@title}</div>
        <div class="text-base-content/60 mt-0.5 text-xs">{@hint}</div>
      </div>
      <div class="shrink-0">{render_slot(@inner_block)}</div>
    </div>
    """
  end
end
