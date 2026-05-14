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
