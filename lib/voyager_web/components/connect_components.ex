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
        class="font-mono text-[12px] text-base-content/60 flex min-w-0 flex-1 cursor-pointer items-center gap-2.5 rounded-md px-3 py-2 transition-colors hover:bg-base-200 hover:text-base-content"
      >
        <.icon name="icon-network" class="size-3.5 text-base-content/25 shrink-0" />
        <div class="flex min-w-0 items-center gap-1.5">
          <span class="ml-2 truncate">{@conn.node_name}</span>
          <%= if @conn.cookie do %>
            <span
              title="Cookie saved"
              class="font-mono text-[9px] text-base-content/30 border-base-300 shrink-0 rounded border px-1"
            >
              cookie
            </span>
          <% end %>
        </div>
        <span class="font-mono text-[10.5px] text-base-content/35 ml-auto shrink-0">
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
          if(@pinned, do: "text-amber-500", else: "text-base-content/20 hover:text-warning")
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
    <div class="mb-5">
      <p class="font-mono text-[10.5px] tracking-[0.08em] text-base-content/50 mb-2.5 uppercase">
        Connected node
      </p>
      <div class="bg-success/10 border-success/25 flex items-center justify-between rounded-lg border px-3.5 py-2.5">
        <div class="flex items-center gap-2.5">
          <span class="size-2 relative flex shrink-0">
            <span class="bg-success size-full absolute inline-flex animate-ping rounded-full opacity-60">
            </span>
            <span class="bg-success size-2 relative inline-flex rounded-full"></span>
          </span>
          <span class="font-mono text-[12px] text-base-content/75 min-w-0 truncate">
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
        to_string(assigns.form[:name_type].value || "shortnames")
      )

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
            class="font-mono text-[10.5px] tracking-[0.08em] text-base-content/50 uppercase"
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
              class="join-item btn btn-soft btn-xs font-mono text-[10px] text-base-content/60 checked:text-primary-content"
            />
            <input
              type="radio"
              name="conn[name_type]"
              value="shortnames"
              aria-label="--sname"
              checked={@current_name_type == "shortnames"}
              disabled={@disabled}
              class="join-item btn btn-soft btn-xs font-mono text-[10px] text-base-content/60 checked:text-primary-content"
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
          class="font-mono text-[13px]"
        />
      </div>

      <div>
        <div class="mb-1.5 flex items-center justify-between">
          <label
            class="font-mono text-[10.5px] tracking-[0.08em] text-base-content/50 uppercase"
            for={@form[:cookie].id}
          >
            Cookie
          </label>
          <button
            type="button"
            phx-click="toggle_cookie"
            disabled={@disabled}
            class="font-mono text-[10px] tracking-[0.06em] text-base-content/40 cursor-pointer uppercase transition-colors hover:text-base-content"
          >
            {if @show_cookie, do: "Hide", else: "Show"}
          </button>
        </div>
        <.input
          field={@form[:cookie]}
          type={if @show_cookie, do: "text", else: "password"}
          placeholder="••••••••••••••••"
          autocomplete="off"
          spellcheck="false"
          disabled={@disabled}
          class="font-mono text-[13px]"
        />
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
          <span class="text-[12.5px] text-base-content/70">Remember cookie</span>
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
