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
      class="font-mono text-base-content/70 border-base-content/20 shrink-0 rounded border px-1 text-xs"
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
        "btn btn-square btn-ghost toolbar-btn-sm",
        if(@pinned, do: "text-pinned", else: "text-base-content/60 hover:text-pinned")
      ]}
    >
      <.icon
        name={if @pinned, do: "icon-star-filled", else: "icon-star"}
        class="toolbar-icon-sm"
      />
    </button>

    <button
      type="button"
      phx-target={@target}
      phx-click={@delete_event}
      phx-value-id={@id}
      title="Remove"
      class="btn btn-square btn-ghost toolbar-btn-sm text-base-content/60 hover:text-error"
    >
      <.icon name="icon-x" class="toolbar-icon-sm" />
    </button>
    """
  end

  attr :session, :any, required: true

  def connected_indicator(%{session: nil} = assigns), do: ~H""

  def connected_indicator(assigns) do
    ~H"""
    <div id="connected-indicator" class="mb-5">
      <p class="font-mono tracking-label text-base-content/70 mb-2.5 text-xs uppercase">
        Connected node
      </p>
      <div class="bg-success-bg border-success flex items-center justify-between rounded-lg border px-3.5 py-2.5">
        <div class="flex min-w-0 items-center gap-1.5">
          <span class="size-2 relative flex shrink-0">
            <span class="bg-success size-full absolute inline-flex animate-ping rounded-full opacity-60"></span>
            <span class="bg-success size-2 relative inline-flex rounded-full"></span>
          </span>
          <span class="font-mono text-base-content/75 min-w-0 truncate text-xs">
            {@session.node_name}
          </span>
          <.tooltip id="disconnect-from-connect-tip" position="bottom">
            <button
              type="button"
              id="disconnect-from-connect"
              phx-click="disconnect"
              aria-label="Disconnect"
              class="btn btn-ghost btn-square toolbar-btn-sm text-error/80 shrink-0 hover:text-error"
            >
              <.icon name="icon-power" class="toolbar-icon-sm" />
            </button>
            <:content>Disconnect</:content>
          </.tooltip>
        </div>
        <.link
          href={~p"/node/#{@session.node_name}"}
          class="btn btn-success btn-xs ml-3 shrink-0 gap-1 dark:text-base-100"
        >
          Open <.icon name="icon-log-in" class="toolbar-icon-sm" />
        </.link>
      </div>
    </div>
    """
  end

  attr :mode, :atom, required: true
  attr :disabled, :boolean, default: false
  attr :reason, :atom, default: nil

  slot :disabled_reason, doc: "Tooltip content displayed when inputs are disabled"

  def mode_toggle(assigns) do
    ~H"""
    <form phx-change="switch_mode" id="mode-toggle" class="mb-6" disabled={@disabled}>
      <.tooltip
        :if={@disabled}
        id={"mode-toggle-tip-#{@reason}"}
        position="bottom"
        class="w-full"
      >
        <.mode_segmented mode={@mode} disabled={@disabled} />
        <:content>{render_slot(@disabled_reason)}</:content>
      </.tooltip>
      <.mode_segmented :if={!@disabled} mode={@mode} disabled={@disabled} />
    </form>
    """
  end

  defp mode_segmented(assigns) do
    ~H"""
    <.segmented
      name="mode"
      value={@mode}
      disabled={@disabled}
      size="sm"
      full_width={true}
      class={["w-full", @disabled && "pointer-events-none cursor-not-allowed"]}
      options={[
        %{value: "direct", label: "Direct", id: "mode-direct"},
        %{value: "ssh", label: "SSH Tunnel", id: "mode-ssh"}
      ]}
    />
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
          class="font-mono tracking-label text-base-content/70 text-xs uppercase"
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
  attr :placeholder, :string, default: nil
  attr :disabled, :boolean, default: false

  def path_field(assigns) do
    ~H"""
    <.form_field field={@field} label={@label} placeholder={@placeholder} disabled={@disabled}>
      <:trailing>
        <.tooltip id={"#{@field.id}-browse-tip"} show_when="browser">
          <button
            type="button"
            id={"#{@field.id}-browse"}
            phx-hook=".PathField"
            data-input-id={@field.id}
            data-default-path={Path.expand("~/.ssh")}
            data-locked={@disabled}
            disabled
            class="btn btn-soft btn-xs gap-1.5 text-xs"
          >
            <.icon name="icon-folder-open" class="size-3.5" /> Browse
          </button>
          <:content>Browsing is available only in the desktop app</:content>
        </.tooltip>
      </:trailing>
    </.form_field>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".PathField">
      export default {
        mounted() {
          this.invoke = window.__TAURI_INTERNALS__?.invoke
          this.sync()
          this.el.addEventListener("click", async () => {
            const {inputId, defaultPath} = this.el.dataset
            const path = await this.invoke("plugin:dialog|open", {options: {defaultPath}})
            if (typeof path !== "string") return

            const input = document.getElementById(inputId)
            input.value = path
            input.dispatchEvent(new Event("input", {bubbles: true}))
          })
        },
        updated() {
          this.sync()
        },
        sync() {
          this.el.disabled = !this.invoke || "locked" in this.el.dataset
        }
      }
    </script>
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
        class="font-mono tracking-label text-base-content/70 mb-1.5 block text-xs uppercase"
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
          class="btn btn-ghost btn-square toolbar-btn text-base-content/60 absolute top-1 right-1.5 hover:text-base-content disabled:opacity-40"
        >
          <.icon name={if @shown, do: "icon-eye", else: "icon-eye-off"} class="toolbar-icon" />
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

  attr :id, :string, required: true
  attr :form, Phoenix.HTML.Form, required: true
  attr :key_path, :string, required: true
  attr :checking, :boolean, default: false
  attr :target, :any, default: nil
  attr :on_change, :string, required: true
  attr :on_submit, :string, required: true
  attr :on_cancel, :string, required: true

  def passphrase_modal(assigns) do
    ~H"""
    <div
      id={@id}
      role="dialog"
      aria-modal="true"
      aria-labelledby={"#{@id}-title"}
      class="modal modal-open"
    >
      <.focus_wrap
        id={"#{@id}-box"}
        phx-mounted={JS.focus_first()}
        class="modal-box border-base-content/20 max-w-md border shadow-2xl"
      >
        <h2 id={"#{@id}-title"} class="text-base-content text-lg font-semibold tracking-tight">
          Key passphrase
        </h2>
        <p class="font-mono text-base-content/70 mt-1 mb-4 truncate text-xs">{@key_path}</p>

        <.form
          for={@form}
          id={"#{@id}-form"}
          phx-target={@target}
          phx-change={@on_change}
          phx-submit={@on_submit}
        >
          <.form_field field={@form[:passphrase]} label="Passphrase" type="password" />

          <div class="modal-action">
            <button
              type="button"
              id={"#{@id}-cancel"}
              phx-target={@target}
              phx-click={@on_cancel}
              class="btn btn-ghost"
            >
              Cancel
            </button>
            <button
              type="submit"
              id={"#{@id}-submit"}
              disabled={@checking}
              class="btn btn-primary gap-2"
            >
              <span :if={@checking} class="loading loading-spinner loading-sm"></span>
              {if @checking, do: "Checking passphrase…", else: "Connect"}
            </button>
          </div>
        </.form>
      </.focus_wrap>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :host, :string, required: true, doc: "`user@host:port` being verified"
  attr :fingerprint, :string, required: true
  attr :password_auth, :boolean, default: false
  attr :target, :any, default: nil
  attr :on_accept, :string, required: true
  attr :on_reject, :string, required: true

  def host_key_modal(assigns) do
    ~H"""
    <div
      id={@id}
      role="dialog"
      aria-modal="true"
      aria-labelledby={"#{@id}-title"}
      class="modal modal-open"
    >
      <.focus_wrap
        id={"#{@id}-box"}
        phx-mounted={JS.focus_first()}
        class="modal-box border-base-300 max-w-xl border shadow-2xl"
      >
        <h2 id={"#{@id}-title"} class="text-base-content text-lg font-semibold tracking-tight">
          Unknown host key
        </h2>
        <p class="text-base-content/70 mt-1 text-sm">
          Voyager has not connected to <span class="font-mono text-base-content">{@host}</span>
          before. Check that its key fingerprint matches the server's before trusting it.
        </p>

        <div class="bg-base-200 mt-4 flex w-full items-center gap-2 rounded-md py-1 pr-1 pl-3">
          <code
            id={"#{@id}-fingerprint"}
            class="font-mono text-base-content min-w-0 flex-1 whitespace-nowrap text-xs"
          >{@fingerprint}</code>
          <.copy_button
            id={"#{@id}-fingerprint-copy"}
            target={"##{@id}-fingerprint"}
            icon_only
            size={:sm}
            label="Copy fingerprint"
            class="shrink-0"
          />
        </div>

        <div
          :if={@password_auth}
          id={"#{@id}-password-warning"}
          role="alert"
          class="alert alert-warning mt-4 text-sm"
        >
          <.icon name="icon-circle-alert" class="size-4 shrink-0" />
          <span>Your SSH password will be sent to this host once you trust it.</span>
        </div>

        <div class="modal-action">
          <button
            type="button"
            id={"#{@id}-reject"}
            phx-target={@target}
            phx-click={@on_reject}
            class="btn btn-ghost"
          >
            Reject
          </button>
          <button
            type="button"
            id={"#{@id}-accept"}
            phx-target={@target}
            phx-click={@on_accept}
            class="btn btn-primary"
          >
            Trust and connect
          </button>
        </div>
      </.focus_wrap>
    </div>
    """
  end

  attr :selected, :map, default: nil
  attr :config_path, :string, required: true
  attr :disabled, :boolean, default: false
  attr :target, :any, default: nil
  attr :on_open, :string, required: true

  def ssh_config_opener(%{selected: nil} = assigns) do
    ~H"""
    <button
      type="button"
      id="ssh-config-open"
      phx-target={@target}
      phx-click={@on_open}
      disabled={@disabled}
      class="btn btn-soft btn-sm w-full gap-2"
    >
      <.icon name="icon-download" class="size-4" /> Import SSH config
    </button>
    """
  end

  def ssh_config_opener(assigns) do
    ~H"""
    <div
      id="ssh-config-filled-from"
      class="border-base-content/20 flex min-w-0 items-center gap-2 rounded-lg border px-3 py-2"
    >
      <.icon name="icon-check" class="text-success size-3.5 shrink-0" />
      <span class="font-mono text-base-content/90 max-w-1/2 shrink-0 truncate text-xs">
        {@selected.alias}
      </span>
      <span class="font-mono text-base-content/70 min-w-0 truncate text-xs">
        from {@config_path}
      </span>
      <button
        type="button"
        id="ssh-config-open"
        phx-target={@target}
        phx-click={@on_open}
        disabled={@disabled}
        class="btn btn-soft btn-xs ml-auto shrink-0 text-xs"
      >
        Change
      </button>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :form, Phoenix.HTML.Form, required: true
  attr :config_path, :string, required: true
  attr :hosts, :list, default: nil, doc: "`nil` until a file has been read"
  attr :unsupported, :list, default: []
  attr :selected, :map, default: nil
  attr :target, :any, default: nil
  attr :on_close, :string, required: true
  attr :on_change_path, :string, required: true
  attr :on_edit_path, :string, required: true
  attr :on_import, :string, required: true
  attr :on_reload, :string, required: true
  attr :on_fill, :string, required: true
  attr :on_remove, :string, required: true

  def ssh_config_modal(assigns) do
    ~H"""
    <div
      id={@id}
      role="dialog"
      aria-modal="true"
      aria-labelledby={"#{@id}-title"}
      class="modal modal-open"
    >
      <.focus_wrap
        id={"#{@id}-box"}
        phx-mounted={JS.focus_first()}
        class="modal-box border-base-content/20 flex max-w-md flex-col gap-3 border shadow-2xl"
      >
        <div>
          <h2 id={"#{@id}-title"} class="text-base-content text-lg font-semibold tracking-tight">
            Import from SSH config
          </h2>
          <p class="text-base-content/70 mt-1 text-xs">Pick a host to fill in the form.</p>
        </div>

        <.form
          :if={is_nil(@hosts)}
          for={@form}
          id={"#{@id}-form"}
          phx-target={@target}
          phx-change={@on_change_path}
          phx-submit={@on_import}
          class="flex flex-col gap-2"
        >
          <.path_field field={@form[:path]} label="Config file" placeholder="~/.ssh/config" />
          <button type="submit" id={"#{@id}-import"} class="btn btn-primary w-full gap-2">
            <.icon name="icon-download" class="size-4" /> Import config
          </button>
        </.form>

        <div :if={@hosts} id={"#{@id}-source"} class="flex min-w-0 items-center gap-1">
          <span class="font-mono text-base-content/70 min-w-0 truncate text-xs">
            {@config_path}
          </span>
          <span class="font-mono text-base-content/70 shrink-0 text-xs">
            · {length(@hosts)} {if length(@hosts) == 1, do: "host", else: "hosts"}
          </span>
          <button
            type="button"
            id={"#{@id}-reload"}
            phx-target={@target}
            phx-click={@on_reload}
            title="Read the file again"
            aria-label="Read the file again"
            class="btn btn-ghost btn-square toolbar-btn-sm text-base-content/60 ml-auto shrink-0 hover:text-base-content"
          >
            <.icon name="icon-rotate-cw" class="toolbar-icon-sm" />
          </button>
          <button
            type="button"
            id={"#{@id}-edit-path"}
            phx-target={@target}
            phx-click={@on_edit_path}
            class="btn btn-soft btn-xs shrink-0 text-xs"
          >
            Change
          </button>
        </div>

        <.ssh_config_notice :if={@hosts && @unsupported != []} unsupported={@unsupported} />

        <p
          :if={@hosts == []}
          id={"#{@id}-empty"}
          class="text-base-content/70 border-base-content/20 rounded-lg border border-dashed p-4 text-center text-xs"
        >
          No hosts in this file.
        </p>

        <ul
          :if={@hosts not in [nil, []]}
          id={"#{@id}-hosts"}
          class="flex max-h-72 flex-col gap-0.5 overflow-y-auto pr-3"
        >
          <li :for={host <- @hosts} class="list-none">
            <.ssh_host_row
              host={host}
              selected={not is_nil(@selected) and @selected.alias == host.alias}
              target={@target}
              on_fill={@on_fill}
              on_remove={@on_remove}
            />
          </li>
        </ul>

        <div class="modal-action mt-2">
          <button
            type="button"
            id={"#{@id}-close"}
            phx-target={@target}
            phx-click={@on_close}
            class="btn btn-soft btn-sm"
          >
            Close
          </button>
        </div>
      </.focus_wrap>
    </div>
    """
  end

  attr :unsupported, :list, required: true

  def ssh_config_notice(assigns) do
    assigns =
      assign(assigns, :keywords, assigns.unsupported |> Enum.map(& &1.keyword) |> Enum.uniq())

    ~H"""
    <details
      id="ssh-config-notice"
      phx-mounted={JS.ignore_attributes("open")}
      class="group text-base-content/70 text-xs"
    >
      <summary class="summary-plain flex cursor-pointer items-center gap-1.5 transition-colors hover:text-base-content">
        <.icon name="icon-circle-alert" class="text-warning size-3.5 shrink-0" />
        {length(@keywords)} {if length(@keywords) == 1, do: "setting", else: "settings"} ignored
        <.icon
          name="icon-chevron-right"
          class="size-3.5 shrink-0 transition-transform group-open:rotate-90"
        />
      </summary>
      <p class="font-mono bg-base-200 border-base-content/20 mt-1.5 break-words rounded-md border p-2">
        {Enum.join(@keywords, ", ")}
      </p>
    </details>
    """
  end

  attr :host, :map, required: true
  attr :selected, :boolean, default: false
  attr :target, :any, default: nil
  attr :on_fill, :string, required: true
  attr :on_remove, :string, required: true

  def ssh_host_row(assigns) do
    ~H"""
    <div class="flex w-full items-center gap-1">
      <button
        type="button"
        phx-target={@target}
        phx-click={@on_fill}
        phx-value-alias={@host.alias}
        data-testid="fill-ssh-host-btn"
        class={[
          "font-mono text-base-content/90 flex min-w-0 flex-1 cursor-pointer items-center gap-2.5 rounded-md px-3 py-2 text-xs transition-colors hover:bg-base-200 hover:text-base-content",
          @selected && "bg-primary/10"
        ]}
      >
        <.icon name="icon-network" class="size-3.5 text-base-content/60 shrink-0 self-center" />
        <div class="flex min-w-0 flex-1 flex-col gap-1">
          <span class="truncate text-left">{@host.alias}</span>
          <div class="flex flex-wrap items-center gap-1">
            <span class="font-mono text-base-content/70 border-base-content/20 rounded border px-1 text-xs">
              {ssh_host_address(@host)}
            </span>
            <.saved_badge
              :if={@host.identity_files != []}
              label="key"
              title={hd(@host.identity_files)}
            />
            <.saved_badge
              :if={is_binary(@host.identity_agent)}
              label="agent"
              title={@host.identity_agent}
            />
          </div>
        </div>
        <.icon
          :if={@selected}
          name="icon-check"
          class="size-3.5 text-success shrink-0 self-center"
        />
      </button>

      <button
        type="button"
        phx-target={@target}
        phx-click={@on_remove}
        phx-value-alias={@host.alias}
        data-testid="remove-ssh-host-btn"
        title="Remove from this list"
        aria-label={"Remove #{@host.alias} from this list"}
        class="btn btn-square btn-ghost toolbar-btn-sm text-base-content/60 hover:text-error"
      >
        <.icon name="icon-x" class="toolbar-icon-sm" />
      </button>
    </div>
    """
  end

  defp ssh_host_address(host) do
    user = if host.user, do: "#{host.user}@"
    port = if host.port, do: ":#{host.port}"
    "#{user}#{host.host_name || host.alias}#{port}"
  end

  @doc "Segmented radio group for a set of mutually exclusive options."
  attr :name, :string, required: true
  attr :value, :any, required: true, doc: "Currently selected value (compared as a string)"
  attr :options, :list, required: true, doc: "List of `%{value:, label:, id: (optional)}` maps"
  attr :disabled, :boolean, default: false
  attr :size, :string, default: "xs", doc: "DaisyUI button size class (xs, sm, md, lg)"
  attr :full_width, :boolean, default: false
  attr :class, :any, default: nil

  def segmented(assigns) do
    ~H"""
    <div class={["join", @class]}>
      <input
        :for={opt <- @options}
        type="radio"
        name={@name}
        value={opt.value}
        id={opt[:id]}
        aria-label={opt.label}
        checked={to_string(@value) == to_string(opt.value)}
        disabled={@disabled}
        class={
          segmented_radio_class(
            @disabled,
            to_string(@value) == to_string(opt.value),
            @size,
            @full_width
          )
        }
      />
    </div>
    """
  end

  defp segmented_radio_class(disabled?, active?, size, full_width?) do
    [
      "join-item btn btn-soft font-mono text-xs transition-opacity",
      "btn-#{size}",
      if(full_width?, do: "flex-1"),
      "checked:text-primary-content",
      if(disabled? && active?,
        do: "!opacity-100 !bg-base-content/20 !text-primary-content",
        else: "text-base-content/70 disabled:text-base-content/70"
      ),
      disabled? && !active? && "opacity-40"
    ]
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
  attr :loading, :boolean, default: false
  attr :disabled, :boolean, default: false

  def connect_submit(assigns) do
    ~H"""
    <button
      type="submit"
      id={@id}
      disabled={@disabled}
      class={[
        "btn btn-primary mt-2 w-full gap-2 phx-submit-loading:pointer-events-none phx-submit-loading:opacity-70",
        @loading && "pointer-events-none opacity-70"
      ]}
    >
      <.icon name={@icon} class={["size-4", (@loading && "hidden") || "phx-submit-loading:hidden"]} />
      <span class={[(@loading && "hidden") || "phx-submit-loading:hidden"]}>{@label}</span>
      <span class={[
        "loading loading-spinner loading-sm",
        if(@loading, do: "inline-flex", else: "hidden phx-submit-loading:inline-flex")
      ]}></span>
      <span class={[if(@loading, do: "inline", else: "hidden phx-submit-loading:inline")]}>
        {@loading_label}
      </span>
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
