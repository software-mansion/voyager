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

  def info_card(assigns) do
    ~H"""
    <div class="card bg-base-200 border-base-300 border shadow-sm">
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
