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
        <div class="mb-1.5 flex items-center justify-between">
          <label
            class="font-mono tracking-label text-base-content/50 text-xs uppercase"
            for={@form[:cookie].id}
          >
            Cookie
          </label>
          <button
            type="button"
            phx-click="toggle_cookie"
            disabled={@disabled}
            class="font-mono tracking-loose text-base-content/40 cursor-pointer text-xs uppercase transition-colors hover:text-base-content"
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
          class="font-mono text-sm"
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

  attr :mode, :atom, required: true, doc: ":direct or :ssh"
  attr :disabled, :boolean, default: false

  def mode_toggle(assigns) do
    ~H"""
    <form phx-change="switch_mode" id="ssh-mode-toggle" class="mb-6">
      <div class="join w-full">
        <input
          type="radio"
          name="mode"
          value="direct"
          aria-label="Direct"
          id="mode-direct"
          checked={@mode == :direct}
          disabled={@disabled}
          class="join-item btn btn-soft btn-sm font-mono flex-1 text-xs transition-colors checked:text-primary-content disabled:text-base-content/60"
        />
        <input
          type="radio"
          name="mode"
          value="ssh"
          aria-label="SSH Tunnel"
          id="mode-ssh"
          checked={@mode == :ssh}
          disabled={@disabled}
          class="join-item btn btn-soft btn-sm font-mono flex-1 text-xs transition-colors checked:text-primary-content disabled:text-base-content/60"
        />
      </div>
    </form>
    """
  end

  attr :form, :any, required: true, doc: "The Phoenix.HTML.Form map"
  attr :show_ssh_cookie, :boolean, default: false, doc: "Toggles cookie field visibility"
  attr :show_ssh_password, :boolean, default: false, doc: "Toggles auth password visibility"
  attr :show_advanced, :boolean, default: false, doc: "Toggles advanced SSH options visibility"
  attr :connecting, :boolean, default: false, doc: "True while SSH connect is in progress"

  attr :disabled, :boolean,
    default: false,
    doc: "Disables all form inputs when a node is already connected"

  def ssh_connect_form(assigns) do
    assigns =
      assign(
        assigns,
        :current_auth_method,
        to_string(assigns.form[:auth_method].value || "agent")
      )

    assigns =
      assign(
        assigns,
        :current_name_type,
        to_string(assigns.form[:name_type].value || "longnames")
      )

    ~H"""
    <.form
      for={@form}
      id="ssh-connect-form"
      phx-change="validate_ssh"
      phx-submit="connect_ssh"
      class={["flex flex-col gap-4", @disabled && "pointer-events-none opacity-40"]}
    >
      <%!-- SSH Gateway --%>
      <div class="flex gap-3">
        <div class="flex-[1] min-w-0">
          <label
            class="font-mono tracking-label text-base-content/50 mb-1.5 block text-xs uppercase"
            for={@form[:ssh_user].id}
          >
            SSH User
          </label>
          <.input
            field={@form[:ssh_user]}
            type="text"
            placeholder="alice"
            autocomplete="off"
            spellcheck="false"
            disabled={@disabled}
            class="font-mono text-sm"
          />
        </div>
        <div class="flex-[2] min-w-0">
          <label
            class="font-mono tracking-label text-base-content/50 mb-1.5 block text-xs uppercase"
            for={@form[:ssh_host].id}
          >
            SSH Host
          </label>
          <.input
            field={@form[:ssh_host]}
            type="text"
            placeholder="bastion.example.com"
            autocomplete="off"
            spellcheck="false"
            disabled={@disabled}
            class="font-mono text-sm"
          />
        </div>
      </div>

      <%!-- Remote node name --%>
      <div>
        <div class="mb-1.5 flex items-center justify-between">
          <label
            class="font-mono tracking-label text-base-content/50 text-xs uppercase"
            for={@form[:node_name].id}
          >
            Node Name
          </label>
          <div class="join">
            <input
              type="radio"
              name="ssh[name_type]"
              value="longnames"
              aria-label="--name"
              checked={@current_name_type == "longnames"}
              disabled={@disabled}
              class="join-item btn btn-soft btn-xs font-mono text-base-content/60 text-xs checked:text-primary-content disabled:text-base-content/60"
            />
            <input
              type="radio"
              name="ssh[name_type]"
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
          placeholder="myapp@10.0.0.5"
          autocomplete="off"
          spellcheck="false"
          disabled={@disabled}
          class="font-mono text-sm"
        />
      </div>

      <%!-- Cookie --%>
      <div>
        <div class="mb-1.5 flex items-center justify-between">
          <label
            class="font-mono tracking-label text-base-content/50 text-xs uppercase"
            for={@form[:cookie].id}
          >
            Cookie
          </label>
          <button
            type="button"
            phx-click="toggle_ssh_cookie"
            disabled={@disabled}
            class="font-mono tracking-loose text-base-content/40 cursor-pointer text-xs uppercase transition-colors hover:text-base-content"
          >
            {if @show_ssh_cookie, do: "Hide", else: "Show"}
          </button>
        </div>
        <.input
          field={@form[:cookie]}
          type={if @show_ssh_cookie, do: "text", else: "password"}
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
          <input type="hidden" name="ssh[remember_cookie]" value="false" />
          <input
            type="checkbox"
            name="ssh[remember_cookie]"
            value="true"
            checked={to_string(@form[:remember_cookie].value) == "true"}
            disabled={@disabled}
            class="checkbox checkbox-sm"
          />
          <span class="text-base-content/70 text-xs">Remember cookie</span>
        </label>
      </div>

      <%!-- Auth method --%>
      <div>
        <label class="font-mono tracking-label text-base-content/50 mb-1.5 block text-xs uppercase">
          Authentication
        </label>
        <div class="join">
          <input
            type="radio"
            name="ssh[auth_method]"
            value="agent"
            id="ssh-auth-agent"
            aria-label="SSH Agent"
            checked={@current_auth_method == "agent"}
            disabled={@disabled}
            class="join-item btn btn-soft btn-xs font-mono text-base-content/60 text-xs checked:text-primary-content disabled:text-base-content/60"
          />
          <input
            type="radio"
            name="ssh[auth_method]"
            value="password"
            id="ssh-auth-password"
            aria-label="Password"
            checked={@current_auth_method == "password"}
            disabled={@disabled}
            class="join-item btn btn-soft btn-xs font-mono text-base-content/60 text-xs checked:text-primary-content disabled:text-base-content/60"
          />
        </div>
      </div>

      <%!-- Auth password (shown when auth_method == :password) --%>
      <div :if={@current_auth_method == "password"}>
        <div class="mb-1.5 flex items-center justify-between">
          <label
            class="font-mono tracking-label text-base-content/50 text-xs uppercase"
            for={@form[:password].id}
          >
            SSH Password
          </label>
          <button
            type="button"
            phx-click="toggle_ssh_password"
            disabled={@disabled}
            class="font-mono tracking-loose text-base-content/40 cursor-pointer text-xs uppercase transition-colors hover:text-base-content"
          >
            {if @show_ssh_password, do: "Hide", else: "Show"}
          </button>
        </div>
        <.input
          field={@form[:password]}
          type={if @show_ssh_password, do: "text", else: "password"}
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
          <input type="hidden" name="ssh[remember_password]" value="false" />
          <input
            type="checkbox"
            name="ssh[remember_password]"
            value="true"
            checked={to_string(@form[:remember_password].value) == "true"}
            disabled={@disabled}
            class="checkbox checkbox-sm"
          />
          <span class="text-base-content/70 text-xs">Remember password</span>
        </label>
      </div>

      <%!-- Advanced settings --%>
      <div>
        <button
          type="button"
          phx-click="toggle_ssh_advanced"
          class="font-mono tracking-label text-base-content/40 cursor-pointer select-none text-xs uppercase transition-colors hover:text-base-content/70"
        >
          Advanced {if @show_advanced, do: "▾", else: "▸"}
        </button>
        <div :if={@show_advanced} class="border-base-300 mt-3 flex gap-3 rounded-lg border p-4">
          <div class="flex-1">
            <label
              class="font-mono tracking-label text-base-content/50 mb-1.5 block text-xs uppercase"
              for={@form[:ssh_port].id}
            >
              SSH Port
            </label>
            <.input
              field={@form[:ssh_port]}
              type="number"
              min="1"
              max="65535"
              disabled={@disabled}
              class="font-mono text-sm"
            />
          </div>
          <div class="flex-1">
            <label
              class="font-mono tracking-label text-base-content/50 mb-1.5 block text-xs uppercase"
              for={@form[:epmd_port].id}
            >
              EPMD Port
            </label>
            <.input
              field={@form[:epmd_port]}
              type="number"
              min="1"
              max="65535"
              disabled={@disabled}
              class="font-mono text-sm"
            />
          </div>
        </div>
      </div>

      <button
        type="submit"
        id="ssh-connect-btn"
        disabled={@disabled or @connecting}
        class="btn btn-primary mt-2 w-full gap-2 phx-submit-loading:pointer-events-none phx-submit-loading:opacity-70"
      >
        <.icon name="icon-ssh" class="size-4 phx-submit-loading:hidden" />
        <span class="phx-submit-loading:hidden">Connect via SSH</span>
        <span class="loading loading-spinner loading-sm hidden phx-submit-loading:inline-flex"></span>
        <span class="hidden phx-submit-loading:inline">Connecting over SSH…</span>
      </button>
    </.form>
    """
  end

  attr :conn, :map, required: true, doc: "The SSH connection record from the database"
  attr :pinned, :boolean, default: false, doc: "Whether this connection is pinned"

  def ssh_connection_row(assigns) do
    ~H"""
    <div class="flex w-full items-center gap-1">
      <button
        type="button"
        phx-click="fill_ssh_recent"
        phx-value-id={@conn.id}
        data-testid="fill-ssh-recent-btn"
        class="font-mono text-base-content/60 flex min-w-0 flex-1 cursor-pointer items-center gap-2.5 rounded-md px-3 py-2 text-xs transition-colors hover:bg-base-200 hover:text-base-content"
      >
        <.icon name="icon-ssh" class="size-3.5 text-base-content/25 shrink-0 self-start mt-1" />
        <div class="flex min-w-0 flex-1 flex-col gap-1">
          <span class="ml-2 truncate">{@conn.node_name}</span>
          <div class="ml-2 flex flex-wrap items-center gap-1">
            <span class="font-mono text-base-content/30 border-base-300 rounded border px-1 text-xs">
              {@conn.ssh_user}@{@conn.ssh_host}
            </span>
            <%= if @conn.cookie do %>
              <span
                title="Cookie saved"
                class="font-mono text-base-content/30 border-base-300 rounded border px-1 text-xs"
              >
                cookie
              </span>
            <% end %>
            <%= if @conn.password do %>
              <span
                title="Password saved"
                class="font-mono text-base-content/30 border-base-300 rounded border px-1 text-xs"
              >
                pass
              </span>
            <% end %>
          </div>
        </div>
        <span class="font-mono text-base-content/35 shrink-0 self-start text-xs mt-0.5">
          {relative_time(@conn.last_connected_at)}
        </span>
      </button>

      <%!-- Quick reconnect: available when agent auth or password is stored --%>
      <button
        :if={@conn.auth_method == :agent or not is_nil(@conn.password)}
        type="button"
        phx-click="ssh_reconnect"
        phx-value-id={@conn.id}
        title="Reconnect"
        class="btn btn-ghost btn-xs text-base-content/20 px-0.5 hover:text-primary"
      >
        <.icon name="icon-zap" class="size-3.5" />
      </button>

      <button
        type="button"
        phx-click={if @pinned, do: "unpin_ssh", else: "pin_ssh"}
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
        phx-click="delete_ssh_connection"
        phx-value-id={@conn.id}
        title="Remove"
        class="btn btn-ghost btn-xs text-base-content/20 px-0.5 hover:text-error"
      >
        <.icon name="icon-x" class="size-3.5" />
      </button>
    </div>
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
