defmodule VoyagerWeb.ConnectComponents do
  @moduledoc """
  Components for the node connection flow: the connect form and connection history rows.
  """

  use VoyagerWeb, :component

  @doc "Small bordered badge marking a stored element on a row."
  attr :label, :string, required: true
  attr :title, :string, required: true

  def saved_badge(assigns) do
    ~H"""
    <span
      title={@title}
      class="font-mono text-base-content/30 border-base-300 shrink-0 rounded border px-1 text-xs"
    >
      {@label}
    </span>
    """
  end

  @doc """
   Favourite and delete buttons shared by the connection-history rows.
  """
  attr :id, :any, required: true
  attr :pinned, :boolean, required: true
  attr :pin_event, :string, required: true
  attr :unpin_event, :string, required: true
  attr :delete_event, :string, required: true
  attr :target, :any, default: nil

  def row_actions(assigns) do
    ~H"""
    <button
      type="button"
      phx-target={@target}
      phx-click={if @pinned, do: @unpin_event, else: @pin_event}
      phx-value-id={@id}
      title={if @pinned, do: "Remove from favourites", else: "Save as favourite"}
      class={[
        "btn btn-ghost btn-xs px-0.5",
        if(@pinned, do: "text-pinned", else: "text-base-content/20 hover:text-pinned")
      ]}
    >
      <.icon name={if @pinned, do: "icon-star-filled", else: "icon-star"} class="size-3.5" />
    </button>

    <button
      type="button"
      phx-target={@target}
      phx-click={@delete_event}
      phx-value-id={@id}
      title="Remove"
      class="btn btn-ghost btn-xs text-base-content/20 px-0.5 hover:text-error"
    >
      <.icon name="icon-x" class="size-3.5" />
    </button>
    """
  end

  attr :session, :any, required: true

  def connected_indicator(%{session: nil} = assigns), do: ~H""

  def connected_indicator(assigns) do
    ~H"""
    <div class="mb-5">
      <p class="font-mono tracking-label text-base-content/50 mb-2.5 text-xs uppercase">
        Connected node
      </p>
      <div class="bg-success/10 border-success/25 flex items-center justify-between rounded-lg border px-3.5 py-2.5">
        <div class="flex items-center gap-2.5">
          <span class="size-2 relative flex shrink-0">
            <span class="bg-success size-full absolute inline-flex animate-ping rounded-full opacity-60">
            </span>
            <span class="bg-success size-2 relative inline-flex rounded-full"></span>
          </span>
          <span class="font-mono text-base-content/75 min-w-0 truncate text-xs">
            {@session.node_name}
          </span>
        </div>
        <.link
          href={~p"/node/#{@session.node_name}"}
          class="btn btn-success btn-xs ml-3 shrink-0 gap-1"
        >
          Open <.icon name="icon-arrow-right" class="size-3" />
        </.link>
      </div>
    </div>
    """
  end

  attr :mode, :atom, required: true
  attr :disabled, :boolean, default: false

  slot :disabled_reason, doc: "Tooltip content displayed when inputs are disabled"

  def mode_toggle(assigns) do
    ~H"""
    <form phx-change="switch_mode" id="mode-toggle" class="mb-6">
      <.tooltip :if={@disabled} id="mode-toggle-tip" position="bottom" class="w-full">
        <.mode_options mode={@mode} disabled={@disabled} />
        <:content>{render_slot(@disabled_reason)}</:content>
      </.tooltip>
      <.mode_options :if={!@disabled} mode={@mode} disabled={@disabled} />
    </form>
    """
  end

  attr :mode, :atom, required: true
  attr :disabled, :boolean, required: true

  defp mode_options(assigns) do
    ~H"""
    <div class={["join w-full", @disabled && "pointer-events-none cursor-not-allowed"]}>
      <input
        type="radio"
        name="mode"
        value="direct"
        aria-label="Direct"
        id="mode-direct"
        checked={@mode == :direct}
        disabled={@disabled}
        class={mode_radio_class(@disabled, @mode == :direct)}
      />
      <input
        type="radio"
        name="mode"
        value="ssh"
        aria-label="SSH Tunnel"
        id="mode-ssh"
        checked={@mode == :ssh}
        disabled={@disabled}
        class={mode_radio_class(@disabled, @mode == :ssh)}
      />
    </div>
    """
  end

  defp mode_radio_class(disabled?, active?) do
    [
      "join-item btn btn-soft btn-sm font-mono flex-1 text-xs transition-opacity",
      "checked:text-primary-content",
      if(disabled? && active?,
        do: "!opacity-100 !bg-base-content/20 !text-primary-content",
        else: "text-base-content/60 disabled:text-base-content/60"
      ),
      disabled? && !active? && "opacity-40"
    ]
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :type, :string, default: "text"
  attr :placeholder, :string, default: nil
  attr :disabled, :boolean, default: false
  attr :rest, :global, include: ~w(min max)
  slot :trailing

  def form_field(assigns) do
    ~H"""
    <div>
      <div class="mb-1.5 flex items-center justify-between">
        <label
          class="font-mono tracking-label text-base-content/50 text-xs uppercase"
          for={@field.id}
        >
          {@label}
        </label>
        {render_slot(@trailing)}
      </div>
      <.input
        field={@field}
        type={@type}
        placeholder={@placeholder}
        autocomplete="off"
        spellcheck="false"
        disabled={@disabled}
        class="font-mono text-sm"
        {@rest}
      />
    </div>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true

  attr :secret_key, :string,
    required: true,
    doc: "Identifies this field for the shared visibility-toggle hook"

  attr :shown, :boolean, default: false
  attr :remember_name, :string, required: true
  attr :remember_checked, :boolean, default: false
  attr :remember_label, :string, required: true
  attr :disabled, :boolean, default: false
  attr :target, :any, default: nil

  def secret_field(assigns) do
    value = assigns.field.value
    assigns = assign(assigns, :value_present?, is_binary(value) and value != "")

    ~H"""
    <div>
      <label
        class="font-mono tracking-label text-base-content/50 mb-1.5 block text-xs uppercase"
        for={@field.id}
      >
        {@label}
      </label>
      <div class="relative">
        <.input
          field={@field}
          type={if @shown, do: "text", else: "password"}
          placeholder="••••••••••••••••"
          autocomplete="off"
          spellcheck="false"
          disabled={@disabled}
          class="font-mono pr-10 text-sm"
        />
        <button
          :if={@value_present?}
          type="button"
          id={"toggle-#{@field.id}-visibility"}
          phx-target={@target}
          phx-click="toggle_secret_visibility"
          phx-value-key={@secret_key}
          disabled={@disabled}
          aria-label={if @shown, do: "Hide", else: "Show"}
          title={if @shown, do: "Hide", else: "Show"}
          class="btn btn-ghost btn-square btn-sm text-base-content/40 absolute top-1 right-1.5 hover:text-base-content"
        >
          <.icon name={if @shown, do: "icon-eye", else: "icon-eye-off"} class="size-5" />
        </button>
      </div>
      <label class={[
        "mt-2.5 flex items-center gap-2",
        if(@disabled, do: "cursor-not-allowed", else: "cursor-pointer")
      ]}>
        <input type="hidden" name={@remember_name} value="false" />
        <input
          type="checkbox"
          name={@remember_name}
          value="true"
          checked={@remember_checked}
          disabled={@disabled}
          class="checkbox checkbox-sm"
        />
        <span class="text-base-content/70 text-xs">{@remember_label}</span>
      </label>
    </div>
    """
  end

  @doc "Segmented radio group for a set of mutually exclusive options."
  attr :name, :string, required: true
  attr :value, :any, required: true, doc: "Currently selected value (compared as a string)"
  attr :options, :list, required: true, doc: "List of `%{value:, label:, id: (optional)}` maps"
  attr :disabled, :boolean, default: false

  def segmented(assigns) do
    ~H"""
    <div class="join">
      <input
        :for={opt <- @options}
        type="radio"
        name={@name}
        value={opt.value}
        id={opt[:id]}
        aria-label={opt.label}
        checked={to_string(@value) == to_string(opt.value)}
        disabled={@disabled}
        class="join-item btn btn-soft btn-xs font-mono text-base-content/60 text-xs checked:text-primary-content disabled:text-base-content/60"
      />
    </div>
    """
  end

  attr :name, :string, required: true
  attr :value, :any, required: true
  attr :disabled, :boolean, default: false

  def name_type_toggle(assigns) do
    ~H"""
    <.segmented
      name={@name}
      value={@value}
      disabled={@disabled}
      options={[
        %{value: "longnames", label: "--name"},
        %{value: "shortnames", label: "--sname"}
      ]}
    />
    """
  end

  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :loading_label, :string, required: true
  attr :disabled, :boolean, default: false

  def connect_submit(assigns) do
    ~H"""
    <button
      type="submit"
      id={@id}
      disabled={@disabled}
      class="btn btn-primary mt-2 w-full gap-2 phx-submit-loading:pointer-events-none phx-submit-loading:opacity-70"
    >
      <.icon name={@icon} class="size-4 phx-submit-loading:hidden" />
      <span class="phx-submit-loading:hidden">{@label}</span>
      <span class="loading loading-spinner loading-sm hidden phx-submit-loading:inline-flex"></span>
      <span class="hidden phx-submit-loading:inline">{@loading_label}</span>
    </button>
    """
  end

  def relative_time(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3_600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3_600)}h ago"
      diff < 604_800 -> "#{div(diff, 86_400)}d ago"
      true -> Calendar.strftime(datetime, "%b %d")
    end
  end
end
