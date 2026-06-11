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
        "alert max-w-[calc(100vw-2rem)] w-80 shadow-md",
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
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", "pb-4"]}>
      <div>
        <h1 class="text-lg font-semibold leading-8">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="text-base-content/70 text-sm">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div :if={@actions != []} class="flex-none">{render_slot(@actions)}</div>
    </header>
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
      "from-primary to-secondary shadow-logo-glow relative h-7 w-7 shrink-0 rounded-md bg-gradient-to-br",
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
      <p :for={error <- @errors} class="font-mono text-[11px] text-error mt-1.5">{error}</p>
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
      <div class="stat-title font-mono text-[10.5px] uppercase tracking-wider">{@title}</div>
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
        <div class="font-mono text-[10px] text-base-content/50 uppercase tracking-wider">
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
      <h2 class="font-mono text-[11px] tracking-[0.15em] text-base-content/50 mb-3 ml-1 font-semibold uppercase">
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
    >
      {render_slot(@inner_block)}
    </span>
    <.portal id={"#{@id}-portal"} target="#tooltip-portal-root">
      <div
        id={"#{@id}-tip"}
        role="tooltip"
        phx-update="ignore"
        class={[
          "tooltip-pop bg-neutral text-neutral-content rounded-box max-w-xs px-3 py-2",
          "ring-base-content/10 text-xs leading-relaxed shadow-lg ring-1"
        ]}
      >
        {render_slot(@content)}
      </div>
    </.portal>
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
  slot :inner_block, doc: "rich tooltip content; overrides text"

  def help_tooltip(assigns) do
    ~H"""
    <.tooltip id={@id} position={@position}>
      <button
        type="button"
        aria-label="Help"
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
    </.tooltip>
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
