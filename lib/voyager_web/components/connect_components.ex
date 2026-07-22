defmodule VoyagerWeb.ConnectComponents do
  @moduledoc """
  Components for the node connection flow: the connect form and connection history rows.
  """

  use VoyagerWeb, :component

  attr :conn, :map, required: true, doc: "The connection record from the database"
  attr :pinned, :boolean, default: false, doc: "Whether this connection is pinned"

  attr :disabled, :boolean,
    default: false,
    doc: "Disables fill-from-recent when a node is already connected"

  def connection_row(assigns) do
    ~H"""
    <div class="flex w-full items-center gap-1">
      <button
        type="button"
        phx-click="fill_recent"
        phx-value-id={@conn.id}
        data-testid="fill-recent-btn"
        disabled={@disabled}
        class={[
          "font-mono text-base-content/60 flex min-w-0 flex-1 items-center gap-2.5 rounded-md px-3 py-2 text-xs transition-colors",
          if(@disabled,
            do: "pointer-events-none opacity-40",
            else: "cursor-pointer hover:bg-base-200 hover:text-base-content"
          )
        ]}
      >
        <.icon name="icon-network" class="size-3.5 text-base-content/25 shrink-0" />
        <div class="flex min-w-0 items-center gap-1.5">
          <span class="ml-2 truncate">{@conn.node_name}</span>
          <%= if @conn.cookie do %>
            <span
              title="Cookie saved"
              class="font-mono text-base-content/30 border-base-300 shrink-0 rounded border px-1 text-xs"
            >
              cookie
            </span>
          <% end %>
        </div>
        <span class="font-mono text-base-content/35 ml-auto shrink-0 text-xs">
          {relative_time(@conn.last_connected_at)}
        </span>
      </button>

      <button
        type="button"
        phx-click={if @pinned, do: "unpin", else: "pin"}
        phx-value-id={@conn.id}
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
        phx-click="delete_connection"
        phx-value-id={@conn.id}
        title="Remove"
        class="btn btn-ghost btn-xs text-base-content/20 px-0.5 hover:text-error"
      >
        <.icon name="icon-x" class="size-3.5" />
      </button>
    </div>
    """
  end

  attr :session, :any, required: true

  def connected_indicator(%{session: nil} = assigns), do: ~H""

  def connected_indicator(assigns) do
    ~H"""
    <div id="connected-indicator" class="mb-5">
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
        <div class="ml-3 flex shrink-0 items-center gap-1">
          <button
            type="button"
            id="disconnect-from-connect"
            phx-click="disconnect"
            title="Disconnect"
            aria-label="Disconnect"
            class="btn btn-ghost btn-square btn-xs btn-error text-error/75 hover:bg-transparent hover:text-error/85 active:text-error/60"
          >
            <.icon name="icon-unplug" class="size-3.5" />
          </button>
          <.link
            href={~p"/node/#{@session.node_name}"}
            class="btn btn-success btn-xs shrink-0 gap-1"
          >
            Open <.icon name="icon-log-in" class="size-3.5" />
          </.link>
        </div>
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
    cookie = assigns.form[:cookie].value

    assigns =
      assigns
      |> assign(:current_name_type, to_string(assigns.form[:name_type].value || "longnames"))
      |> assign(:cookie_present?, is_binary(cookie) and cookie != "")

    ~H"""
    <.form
      for={@form}
      id="connect-form"
      phx-change="validate"
      phx-submit="connect"
      class={["flex flex-col gap-4", @disabled && "pointer-events-none opacity-40"]}
    >
      <div>
        <div class="mb-1.5 flex items-center justify-between">
          <label
            class="font-mono tracking-label text-base-content/50 text-xs uppercase"
            for={@form[:node_name].id}
          >
            Node name
          </label>
          <div class="join">
            <input
              type="radio"
              name="conn[name_type]"
              value="longnames"
              aria-label="--name"
              checked={@current_name_type == "longnames"}
              disabled={@disabled}
              class="join-item btn btn-soft btn-xs font-mono text-base-content/60 text-xs checked:text-primary-content disabled:text-base-content/60"
            />
            <input
              type="radio"
              name="conn[name_type]"
              value="shortnames"
              aria-label="--sname"
              checked={@current_name_type == "shortnames"}
              disabled={@disabled}
              class="join-item btn btn-soft btn-xs font-mono text-base-content/60 text-xs checked:text-primary-content disabled:text-base-content/60"
            />
          </div>
        </div>
        <.input
          field={@form[:node_name]}
          type="text"
          placeholder="my_app@127.0.0.1"
          autocomplete="off"
          spellcheck="false"
          disabled={@disabled}
          class="font-mono text-sm"
        />
      </div>

      <div>
        <label
          class="font-mono tracking-label text-base-content/50 mb-1.5 block text-xs uppercase"
          for={@form[:cookie].id}
        >
          Cookie
        </label>
        <div class="relative">
          <.input
            field={@form[:cookie]}
            type={if @show_cookie, do: "text", else: "password"}
            placeholder="••••••••••••••••"
            autocomplete="off"
            spellcheck="false"
            disabled={@disabled}
            class="font-mono pr-10 text-sm"
          />
          <button
            :if={@cookie_present?}
            type="button"
            id="toggle-cookie-visibility"
            phx-click="toggle_cookie"
            disabled={@disabled}
            aria-label={if @show_cookie, do: "Hide cookie", else: "Show cookie"}
            title={if @show_cookie, do: "Hide cookie", else: "Show cookie"}
            class="btn btn-ghost btn-square btn-sm text-base-content/40 absolute top-1 right-1.5 hover:text-base-content"
          >
            <.icon
              name={if @show_cookie, do: "icon-eye", else: "icon-eye-off"}
              class="size-5"
            />
          </button>
        </div>
        <label class={[
          "mt-2.5 flex items-center gap-2",
          if(@disabled, do: "cursor-not-allowed", else: "cursor-pointer")
        ]}>
          <input type="hidden" name="conn[remember_cookie]" value="false" />

          <input
            type="checkbox"
            name="conn[remember_cookie]"
            value="true"
            checked={to_string(@form[:remember_cookie].value) == "true"}
            disabled={@disabled}
            class="checkbox checkbox-sm"
          />
          <span class="text-base-content/70 text-xs">Remember cookie</span>
        </label>
      </div>

      <button
        type="submit"
        id="connect-btn"
        disabled={@disabled}
        class="btn btn-primary mt-2 w-full gap-2 phx-submit-loading:pointer-events-none phx-submit-loading:opacity-70"
      >
        <.icon name="icon-network" class="size-4 phx-submit-loading:hidden" />
        <span class="phx-submit-loading:hidden">Connect</span>
        <span class="loading loading-spinner loading-sm hidden phx-submit-loading:inline-flex"></span>
        <span class="hidden phx-submit-loading:inline">Connecting…</span>
      </button>
    </.form>
    """
  end

  defp relative_time(datetime) do
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
