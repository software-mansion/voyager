defmodule VoyagerWeb.ConnectComponents do
  @moduledoc """
  Components for the node connection flow: the connect form and connection history rows.
  """

  use VoyagerWeb, :component

  attr :conn, :map, required: true, doc: "The connection record from the database"
  attr :pinned, :boolean, default: false, doc: "Whether this connection is pinned"

  def connection_row(assigns) do
    ~H"""
    <div class="flex w-full items-center gap-1">
      <button
        type="button"
        phx-click="fill_recent"
        phx-value-id={@conn.id}
        data-testid="fill-recent-btn"
        class="font-mono text-base-content/60 flex min-w-0 flex-1 cursor-pointer items-center gap-2.5 rounded-md px-3 py-2 text-xs transition-colors hover:bg-base-200 hover:text-base-content"
      >
        <.icon name="icon-network" class="size-3.5 text-base-content/25 shrink-0" />
        <div class="flex min-w-0 items-center gap-1.5">
          <span class="ml-2 truncate">{@conn.node_name}</span>
          <.saved_badge :if={@conn.cookie} label="cookie" title="Cookie saved" />
        </div>
        <span class="font-mono text-base-content/35 ml-auto shrink-0 text-xs">
          {relative_time(@conn.last_connected_at)}
        </span>
      </button>

      <.row_actions
        id={@conn.id}
        pinned={@pinned}
        pin_event="pin"
        unpin_event="unpin"
        delete_event="delete_connection"
      />
    </div>
    """
  end

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
          navigate={~p"/node/#{@session.node_name}"}
          class="btn btn-success btn-xs ml-3 shrink-0 gap-1"
        >
          Open <.icon name="icon-arrow-right" class="size-3" />
        </.link>
      </div>
    </div>
    """
  end

  attr :form, :any, required: true, doc: "The Phoenix.HTML.Form map"
  attr :show_cookie, :boolean, default: false, doc: "Toggles cookie visibility"

  attr :disabled, :boolean,
    default: false,
    doc: "Disables all form inputs when a node is already connected"

  def connect_form(assigns) do
    assigns =
      assign(
        assigns,
        :current_name_type,
        to_string(assigns.form[:name_type].value || "longnames")
      )

    ~H"""
    <.form
      for={@form}
      id="connect-form"
      phx-change="validate"
      phx-submit="connect"
      class={["flex flex-col gap-4", @disabled && "pointer-events-none opacity-40"]}
    >
      <.form_field
        field={@form[:node_name]}
        label="Node name"
        placeholder="my_app@127.0.0.1"
        disabled={@disabled}
      >
        <:trailing>
          <.name_type_toggle name="conn[name_type]" value={@current_name_type} disabled={@disabled} />
        </:trailing>
      </.form_field>

      <.secret_field
        field={@form[:cookie]}
        label="Cookie"
        shown={@show_cookie}
        toggle_event="toggle_cookie"
        remember_name="conn[remember_cookie]"
        remember_checked={to_string(@form[:remember_cookie].value) == "true"}
        remember_label="Remember cookie"
        disabled={@disabled}
      />

      <.connect_submit
        id="connect-btn"
        icon="icon-network"
        label="Connect"
        loading_label="Connecting…"
        disabled={@disabled}
      />
    </.form>
    """
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
  attr :shown, :boolean, default: false
  attr :toggle_event, :string, required: true
  attr :remember_name, :string, required: true
  attr :remember_checked, :boolean, default: false
  attr :remember_label, :string, required: true
  attr :disabled, :boolean, default: false
  attr :target, :any, default: nil

  def secret_field(assigns) do
    ~H"""
    <div>
      <div class="mb-1.5 flex items-center justify-between">
        <label
          class="font-mono tracking-label text-base-content/50 text-xs uppercase"
          for={@field.id}
        >
          {@label}
        </label>
        <button
          type="button"
          phx-target={@target}
          phx-click={@toggle_event}
          disabled={@disabled}
          class="font-mono tracking-loose text-base-content/40 cursor-pointer text-xs uppercase transition-colors hover:text-base-content"
        >
          {if @shown, do: "Hide", else: "Show"}
        </button>
      </div>
      <.input
        field={@field}
        type={if @shown, do: "text", else: "password"}
        placeholder="••••••••••••••••"
        autocomplete="off"
        spellcheck="false"
        disabled={@disabled}
        class="font-mono text-sm"
      />
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
