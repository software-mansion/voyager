defmodule VoyagerWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  The foundation for styling is Tailwind CSS augmented with a custom design
  system defined in `assets/css/styles/tokens.css`. Icons are loaded from
  `assets/css/icons/` via the Tailwind plugin at `assets/vendor/icons.js`.

    * [Tailwind CSS](https://tailwindcss.com)
    * [Phoenix.Component](https://hexdocs.pm/phoenix_live_view/Phoenix.Component.html)

  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS
  alias VoyagerWeb.Formatters

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash
        id="welcome-back"
        kind={:info}
        phx-mounted={show("#welcome-back") |> JS.remove_attribute("hidden")}
        hidden
      >
        Welcome Back!
      </.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class={[
        "alert flash-constrained w-80 shadow-md",
        "!flex !flex-row items-center text-left",
        @kind == :info && "alert-info",
        @kind == :error && "alert-error"
      ]}
      {@rest}
    >
      <.icon :if={@kind == :info} name="icon-info" class="size-4 shrink-0" />
      <.icon :if={@kind == :error} name="icon-circle-alert" class="size-4 shrink-0" />
      <div class="min-w-0 flex-1">
        <p :if={@title} class="font-bold">{@title}</p>
        <p>{msg}</p>
      </div>
      <button type="button" class="btn btn-ghost btn-xs btn-circle" aria-label="close">
        <.icon name="icon-x" class="size-3.5" />
      </button>
    </div>
    """
  end

  @doc """
  Renders a page header for a connected node, showing the node name and the
  last-updated time, with an optional `actions` slot rendered on the right.
  """
  attr :node_name, :string, required: true
  attr :last_updated, :any, default: nil

  attr :waiting_message, :string,
    default: "waiting for first snapshot…",
    doc: "shown until the first update arrives"

  slot :actions

  def node_header(assigns) do
    ~H"""
    <header class="mb-8 flex flex-wrap items-center justify-between gap-4">
      <div>
        <h1 class="font-mono text-base-content text-2xl font-bold tracking-tight">
          {@node_name}
        </h1>
        <p class="font-mono text-base-content/50 mt-0.5 text-xs">
          <%= if @last_updated do %>
            updated {Formatters.format_time(@last_updated)} UTC
          <% else %>
            {@waiting_message}
          <% end %>
        </p>
      </div>
      <div :if={@actions != []} class="flex items-center gap-2">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a form with select input with specified refresh interval options and
  button to refresh manually.

  ## Examples

      <.interval_select
        options={[
          {"Off", "off"},
          {"1s", "1000"},
          {"2s", "2000"},
        ]}
        refresh_interval={@refresh_interval} # number of milliseconds or nil
        loading={@loading}
      />
  """
  attr :id, :string, default: nil
  attr :options, :list, required: true
  attr :refresh_interval, :integer, default: nil
  attr :loading, :boolean, required: true

  def interval_select(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <label class="font-mono text-base-content/50 tracking-label text-xs uppercase">
        Auto-refresh
      </label>
      <form phx-change="set_interval" id={"#{@id}-form"}>
        <select
          name="interval"
          id={@id}
          class="select select-bordered select-sm font-mono pr-8 text-xs"
        >
          <option
            :for={{label, value} <- @options}
            value={value}
            selected={value == interval_value(@refresh_interval)}
          >
            {label}
          </option>
        </select>
      </form>
      <button
        type="button"
        phx-click="refresh_now"
        phx-throttle="1000"
        id={"#{@id}-refresh-now-button"}
        title="Refresh now"
        class="btn btn-md btn-ghost btn-square"
      >
        <.icon
          name="icon-rotate-cw"
          class={["size-6", @loading && "animate-spin"]}
        />
      </button>
    </div>
    """
  end

  defp interval_value(nil), do: "off"
  defp interval_value(ms), do: Integer.to_string(ms)

  @doc """
  Renders a button that copies text from another element.

  ## Examples

      <.copy_button id="copy-json" target="#json-content" />
  """
  attr :id, :string, required: true
  attr :target, :string, required: true, doc: "CSS selector for the element whose text is copied"
  attr :label, :string, default: "Copy"
  attr :copied_label, :string, default: "Copied"
  attr :icon_only, :boolean, default: false, doc: "hides the visible label"
  attr :class, :any, default: nil
  attr :rest, :global

  def copy_button(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      phx-hook=".CopyToClipboard"
      phx-update="ignore"
      data-copy-target={@target}
      data-copy-label={@label}
      data-copy-copied-label={@copied_label}
      title={@label}
      aria-label={@label}
      class={["btn btn-sm btn-ghost", if(@icon_only, do: "btn-square", else: "gap-2"), @class]}
      {@rest}
    >
      <.icon name="icon-copy" class="size-4" />
      <span data-copy-button-label class={@icon_only && "sr-only"}>{@label}</span>
      <span class="sr-only" aria-live="polite" data-copy-status></span>
    </button>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyToClipboard">
      export default {
        mounted() {
          this.resetTimer = null
          this.onClick = () => this.copyTarget()
          this.el.addEventListener("click", this.onClick)
        },

        destroyed() {
          this.el.removeEventListener("click", this.onClick)
          window.clearTimeout(this.resetTimer)
        },

        async copyTarget() {
          const target = document.querySelector(this.el.dataset.copyTarget)

          if (!target) {
            this.showResult(false)
            return
          }

          const text = target.textContent || ""

          try {
            if (!navigator.clipboard?.writeText) throw new Error("Clipboard API unavailable")
            await navigator.clipboard.writeText(text)
            this.showResult(true)
          } catch (_error) {
            this.showResult(this.copyWithFallback(text))
          }
        },

        copyWithFallback(text) {
          const textarea = document.createElement("textarea")
          textarea.value = text
          textarea.setAttribute("readonly", "")
          textarea.style.position = "fixed"
          textarea.style.opacity = "0"
          document.body.appendChild(textarea)
          textarea.select()

          try {
            return document.execCommand("copy")
          } catch (_error) {
            return false
          } finally {
            textarea.remove()
          }
        },

        showResult(copied) {
          const label = this.el.querySelector("[data-copy-button-label]")
          const status = this.el.querySelector("[data-copy-status]")
          const originalLabel = this.el.dataset.copyLabel
          const resultLabel = copied ? this.el.dataset.copyCopiedLabel : "Copy failed"

          label.textContent = resultLabel
          status.textContent = resultLabel
          this.el.setAttribute("aria-label", resultLabel)
          this.el.setAttribute("title", resultLabel)

          window.clearTimeout(this.resetTimer)
          this.resetTimer = window.setTimeout(() => {
            label.textContent = originalLabel
            status.textContent = ""
            this.el.setAttribute("aria-label", originalLabel)
            this.el.setAttribute("title", originalLabel)
          }, 1800)
        }
      }
    </script>
    """
  end

  @doc """
  Renders an icon from `assets/css/icons/`. The Tailwind plugin at
  `assets/vendor/icons.js` generates an `icon-{name}` CSS class for each
  SVG file in that directory.

  You can customize size and color with Tailwind classes.

  ## Examples

      <.icon name="icon-x" />
      <.icon name="icon-rotate-cw" class="size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true, doc: "icon name, e.g. \"icon-x\""
  attr :class, :any, default: nil
  attr :rest, :global

  def icon(%{name: "icon-" <> _} = assigns) do
    ~H"""
    <span class={[@name | List.wrap(@class)]} {@rest}></span>
    """
  end

  @doc """
  Renders the Voyager logo mark.

  ## Examples

      <.logo />
      <.logo class="h-7 w-7" />
  """
  attr :class, :string, default: nil

  def logo(assigns) do
    ~H"""
    <div class={[
      "from-primary to-secondary shadow-logo-glow relative m-1 h-7 w-7 shrink-0 rounded-md bg-gradient-to-br",
      @class
    ]}>
      <div class="bg-base-100 shadow-logo-inset absolute inset-1 rounded-sm"></div>
    </div>
    """
  end

  @doc """
  Renders a DaisyUI form input, wired to a `Phoenix.HTML.FormField`.

  ## Examples

      <.input field={@form[:email]} type="email" placeholder="you@example.com" />
      <.input field={@form[:password]} type="password" />
  """
  attr :id, :any, default: nil
  attr :name, :any, default: nil
  attr :value, :any, default: nil
  attr :type, :string, default: "text"
  attr :errors, :list, default: []
  attr :class, :any, default: nil
  attr :field, Phoenix.HTML.FormField

  attr :rest, :global,
    include:
      ~w(autocomplete disabled form max maxlength min minlength pattern placeholder required spellcheck step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    assigns
    |> assign(field: nil)
    |> assign(:id, assigns[:id] || field.id)
    |> assign(:name, field.name)
    |> assign(:value, field.value)
    |> assign(:errors, Enum.map(field.errors, &translate_error(&1)))
    |> input()
  end

  def input(%{type: "number-stepper"} = assigns) do
    ~H"""
    <div>
      <div class="join" id={"#{@id}-stepper"} phx-hook="NumberStepper">
        <button
          type="button"
          data-direction="-1"
          tabindex="-1"
          aria-label="Decrease"
          class="btn btn-sm btn-square join-item border-base-content/20"
        >
          <.icon name="icon-minus" class="size-4" />
        </button>
        <input
          type="number"
          id={@id}
          name={@name}
          value={Phoenix.HTML.Form.normalize_value("number", @value)}
          inputmode="numeric"
          class={[
            "input input-sm input-bordered join-item no-spinner font-mono w-14 text-center",
            @errors != [] && "input-error",
            @class
          ]}
          {@rest}
        />
        <button
          type="button"
          data-direction="1"
          tabindex="-1"
          aria-label="Increase"
          class="btn btn-sm btn-square join-item border-base-content/20"
        >
          <.icon name="icon-plus" class="size-4" />
        </button>
      </div>
      <p :for={error <- @errors} class="font-mono text-error mt-1.5 text-xs">{error}</p>
    </div>
    """
  end

  def input(assigns) do
    ~H"""
    <div class="w-full">
      <input
        type={@type}
        id={@id}
        name={@name}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class={["input input-bordered w-full", @errors != [] && "input-error", @class]}
        {@rest}
      />
      <p :for={error <- @errors} class="font-mono text-error mt-1.5 text-xs">{error}</p>
    </div>
    """
  end

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  @doc """
  Renders a single DaisyUI `stat` tile.

  ## Examples

      <.stat title="Processes" value="1,234" value_class="text-primary" />
  """
  attr :title, :string, required: true
  attr :value, :string, required: true
  attr :value_class, :any, default: nil

  def stat(assigns) do
    ~H"""
    <div class="stat">
      <div class="stat-title font-mono tracking-label text-xs uppercase">{@title}</div>
      <div class={["stat-value tabular-nums", @value_class]}>{@value}</div>
    </div>
    """
  end

  @doc """
  Renders a labelled card for a single metric, sized for grids of details.
  """
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :rest, :global

  def info_card(assigns) do
    ~H"""
    <div class="card bg-base-200 border-base-300 border shadow-sm" {@rest}>
      <div class="card-body justify-center gap-1 p-4">
        <div class="font-mono text-base-content/50 tracking-label text-xs uppercase">
          {@label}
        </div>
        <div class="font-mono text-base-content truncate text-sm font-semibold" title={@value}>
          {@value}
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Wraps a grid of `<.info_card>` tiles under a section heading.
  """
  attr :title, :string, required: true
  slot :inner_block, required: true

  def info_section(assigns) do
    ~H"""
    <section class="mb-8">
      <h2 class="font-mono tracking-display text-base-content/50 mb-3 ml-1 text-xs font-semibold uppercase">
        {@title}
      </h2>
      <div class="grid grid-cols-2 gap-4 sm:grid-cols-4">
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  @doc """
  Renders a centered loading spinner with a message.
  """
  attr :id, :string, required: true
  attr :message, :string, required: true
  attr :rest, :global

  def loading_state(assigns) do
    ~H"""
    <div class="flex items-center justify-center gap-3 py-24" id={@id} {@rest}>
      <span class="loading loading-spinner loading-md text-primary"></span>
      <span class="font-mono text-base-content/50 text-sm">{@message}</span>
    </div>
    """
  end

  @doc """
  Renders an inline error alert.
  """
  attr :id, :string, required: true
  attr :message, :string, required: true
  attr :rest, :global

  def error_state(assigns) do
    ~H"""
    <div class="alert alert-error mb-8" id={@id} role="alert" {@rest}>
      <.icon name="icon-circle-alert" class="size-5" />
      <span>{@message}</span>
    </div>
    """
  end

  @doc """
  Renders an arbitrary `trigger` with a tooltip that reveals on hover/focus.

  The tooltip content is teleported via `<.portal>` to `#tooltip-portal-root`
  (rendered in the root layout), so it renders above and outside any modal,
  drawer, or `overflow-hidden` container and is never clipped. Positioning is
  handled by the `Tooltip` JS hook.

  This is the low-level primitive; for the common "?" help affordance use
  `help_tooltip/1`, which wraps this component.

  ## Examples

      <.tooltip id="status-tip" position="bottom">
        <.badge>online</.badge>
        <:content>Node responded to the last heartbeat.</:content>
      </.tooltip>
  """
  attr :id, :string, required: true, doc: "unique DOM id for the trigger"

  attr :position, :string,
    default: "top",
    values: ~w(top bottom left right),
    doc: "preferred side to place the tooltip"

  attr :class, :any, default: nil, doc: "extra classes for the trigger wrapper"
  attr :tip_class, :any, default: nil, doc: "extra classes for the tip"

  attr :interactive, :boolean,
    default: false,
    doc:
      "when true, the tip stays open while hovered and can be pinned open with a click — required if the content holds clickable elements"

  slot :inner_block, required: true, doc: "the hover/focus target"
  slot :content, required: true, doc: "tooltip content"

  def tooltip(assigns) do
    ~H"""
    <span
      id={@id}
      class={["inline-flex align-middle leading-none", @class]}
      phx-hook="Tooltip"
      data-tooltip-target={"##{@id}-tip"}
      data-tooltip-position={@position}
      data-tooltip-interactive={to_string(@interactive)}
    >
      {render_slot(@inner_block)}
    </span>
    <.portal id={"#{@id}-portal"} target="#tooltip-portal-root">
      <div
        id={"#{@id}-tip"}
        role="tooltip"
        phx-update="ignore"
        class={[
          "tooltip-pop bg-base-100 text-base-content rounded-box max-w-xs px-3 py-2",
          "ring-base-content/15 text-xs leading-relaxed shadow-lg ring-1",
          @interactive && "is-interactive",
          @tip_class
        ]}
      >
        {render_slot(@content)}
      </div>
    </.portal>
    """
  end

  @doc """
  Renders a tooltip trigger with a content slot, and optionally appends an external
  documentation link (when `doc_href` is set).

  This is a thin wrapper over `tooltip/1`.
  """
  attr :id, :string, required: true, doc: "unique DOM id for the trigger"

  attr :position, :string,
    default: "top",
    values: ~w(top bottom left right),
    doc: "preferred side to place the tooltip"

  attr :doc_href, :string,
    default: nil,
    doc: "when set, renders a documentation link at the bottom of the tooltip"

  attr :doc_label, :string, default: "Learn more", doc: "label for the documentation link"

  attr :interactive, :boolean,
    default: true,
    doc: "when true, the tip can be hovered into and pinned open with a click"

  slot :inner_block, required: true, doc: "the hover/focus target"
  slot :content, required: true, doc: "tooltip content"

  def link_tooltip(assigns) do
    ~H"""
    <.tooltip id={@id} position={@position} interactive={@interactive}>
      {render_slot(@inner_block)}
      <:content>
        {render_slot(@content)}
        <a
          :if={@doc_href}
          href={@doc_href}
          target="_blank"
          rel="noopener noreferrer"
          class="text-primary mt-2 flex w-fit items-center gap-1 font-medium underline-offset-2 transition-colors hover:text-primary hover:underline"
        >
          {@doc_label}
          <.icon name="icon-external-link" class="size-3" />
        </a>
      </:content>
    </.tooltip>
    """
  end

  @doc """
  Renders a round "?" help affordance that reveals a tooltip on hover/focus.

  Thin wrapper over `tooltip/1` that supplies the "?" trigger button. Pass plain
  text via `text`, or richer markup as the inner block.

  ## Examples

      <.help_tooltip id="cpu-help" text="Average scheduler utilization." />

      <.help_tooltip id="mem-help" position="right">
        Total memory allocated by the BEAM, including
        <span class="font-semibold">processes</span> and binaries.
      </.help_tooltip>
  """
  attr :id, :string, required: true, doc: "unique DOM id for the trigger"
  attr :text, :string, default: nil, doc: "tooltip text; ignored when an inner block is given"

  attr :position, :string,
    default: "top",
    values: ~w(top bottom left right),
    doc: "preferred side to place the tooltip"

  attr :class, :any, default: nil, doc: "extra classes for the trigger button"

  attr :doc_href, :string,
    default: nil,
    doc: "when set, renders a documentation link at the bottom of the tooltip"

  attr :doc_label, :string, default: "Learn more", doc: "label for the documentation link"

  attr :interactive, :boolean,
    default: true,
    doc: "when true, the tip can be hovered into and pinned open with a click"

  slot :inner_block, doc: "rich tooltip content; overrides text"

  def help_tooltip(assigns) do
    ~H"""
    <.link_tooltip
      id={@id}
      position={@position}
      doc_href={@doc_href}
      doc_label={@doc_label}
      interactive={@interactive}
    >
      <button
        type="button"
        aria-label="Help"
        aria-describedby={"#{@id}-tip"}
        class={[
          "btn btn-circle btn-ghost btn-xs text-base-content/40 hover:text-base-content",
          "transition-colors",
          @class
        ]}
      >
        <.icon name="icon-circle-help" class="size-4" />
      </button>
      <:content>
        <%= if @inner_block != [] do %>
          {render_slot(@inner_block)}
        <% else %>
          {@text}
        <% end %>
      </:content>
    </.link_tooltip>
    """
  end

  @doc """
  Collapsible element. It doesn't perform any client-side actions.


  ## Examples

      <.collapsible id="collapsible" open={true}>
        <:label :let={open}>
          <%= if(open, do: "Open", else: "Closed") %>
        </:label>
        <div>Content</div>
      </.collapsible>
  """

  attr(:open, :boolean, required: true, doc: "State of the collapsible")
  attr(:class, :any, default: nil, doc: "CSS class for parent container")
  attr(:label_class, :any, default: nil, doc: "CSS class for the label")
  attr(:chevron_class, :any, default: nil, doc: "CSS class for the chevron icon")

  attr(:rest, :global)

  slot(:right)
  slot(:label, required: true)
  slot(:inner_block, required: true)

  def collapsible(assigns) do
    ~H"""
    <div class={["block" | List.wrap(@class)]}>
      <div class="flex">
        <button
          type="button"
          aria-expanded={@open}
          class={["flex w-full cursor-pointer items-center" | List.wrap(@label_class)]}
          {@rest}
        >
          <.icon
            name="icon-chevron-right"
            class={["shrink-0", if(@open, do: "rotate-90") | List.wrap(@chevron_class)]}
          />
          {render_slot(@label, @open)}
        </button>
        {render_slot(@right, @open)}
      </div>
      <div class={if not @open, do: "hidden"}>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end
end
