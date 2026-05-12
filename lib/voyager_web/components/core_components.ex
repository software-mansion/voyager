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
  use Gettext, backend: VoyagerWeb.Gettext

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
        "flex items-start gap-3 w-80 max-w-[calc(100vw-2rem)] px-4 py-3 rounded-lg bg-surface-bg border border-default-border shadow-card text-[13px] text-primary-text",
        @kind == :info && "[border-left:3px_solid_var(--link)]",
        @kind == :error && "[border-left:3px_solid_var(--bad)]"
      ]}
      {@rest}
    >
      <.icon :if={@kind == :info} name="icon-info" class="shrink-0 size-[18px] mt-px" />
      <.icon :if={@kind == :error} name="icon-circle-alert" class="shrink-0 size-[18px] mt-px" />
      <div class="flex-1 min-w-0">
        <p :if={@title} class="font-semibold mb-0.5">{@title}</p>
        <p>{msg}</p>
      </div>
      <button
        type="button"
        class="cursor-pointer shrink-0 text-faint-text opacity-60 hover:opacity-100"
        aria-label={gettext("close")}
      >
        <.icon name="icon-x" class="size-4" />
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
        <p :if={@subtitle != []} class="text-sm text-base-content/70">
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

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    if count = opts[:count] do
      Gettext.dngettext(VoyagerWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(VoyagerWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
