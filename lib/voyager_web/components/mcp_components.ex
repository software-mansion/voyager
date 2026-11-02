defmodule VoyagerWeb.McpComponents do
  @moduledoc """
  AI agent UI shared by the sidebar popover and the MCP settings card.
  """

  use VoyagerWeb, :component

  alias Voyager.Services.McpAgents
  alias Voyager.Services.McpClients

  @docs_url "https://github.com/software-mansion/voyager#mcp-server"

  @spec docs_url() :: String.t()
  def docs_url, do: @docs_url

  attr :id, :atom,
    default: nil,
    doc: "a `Voyager.Services.McpClients.id()`, nil for any other agent"

  def agent_logo(assigns) do
    ~H"""
    <span class={["size-5.5 flex shrink-0 items-center justify-center rounded-md", logo_tile(@id)]}>
      <.icon
        name={logo_icon(@id)}
        class={["size-3.5", @id == :gemini && "bg-linear-135 from-brand-gemini to-brand-gemini-end"]}
      />
    </span>
    """
  end

  attr :state, :atom, required: true

  def status_dot(assigns) do
    ~H"""
    <span class={[
      "size-1.5 inline-flex shrink-0 rounded-full",
      @state == :off && "bg-error",
      @state == :on && "bg-warning",
      @state == :connected && "bg-success ring-success/30 ring-3"
    ]}></span>
    """
  end

  attr :id, :string, required: true
  attr :text, :string, required: true
  attr :label, :string, required: true
  attr :icon_only, :boolean, default: false

  def copy_text(assigns) do
    ~H"""
    <span id={"#{@id}-text"} class="hidden">{@text}</span>
    <.copy_button
      id={@id}
      target={"##{@id}-text"}
      label={@label}
      icon_only={@icon_only}
      size={:sm}
      class="text-base-content/70 shrink-0 hover:text-base-content"
    />
    """
  end

  @doc "The popover behind the sidebar's AI agents row, for each `McpAgents` state."
  attr :agents, McpAgents, required: true
  attr :settings_path, :string, required: true
  attr :on_turn_on, :string, required: true

  def agents_panel(assigns) do
    ~H"""
    <div id="mcp-agents-panel" class="flex flex-col gap-3 px-1 py-2">
      <div :if={@agents.state == :off} class="flex flex-col gap-3">
        <span class="flex items-center gap-2 text-sm font-semibold">
          <.status_dot state={:off} /> MCP server is off
        </span>
        <p class="text-base-content/70 leading-relaxed">
          Coding agents like Claude Code and Codex can't read this node until you turn the server on.
        </p>
        <div class="flex items-center gap-3">
          <button
            id="mcp-turn-on"
            type="button"
            class="btn btn-primary btn-sm"
            phx-click={@on_turn_on}
          >
            Turn on MCP server
          </button>
          <.link href={@settings_path} class="text-base-content/70 hover:text-base-content">
            MCP settings
          </.link>
        </div>
      </div>

      <div :if={@agents.state != :off} class="flex flex-col gap-3">
        <div class="flex items-center justify-between gap-2">
          <span class="flex items-center gap-2 text-sm font-semibold">
            <.status_dot state={@agents.state} />
            {headline(@agents.connected)}
          </span>
          <span class="flex items-center gap-0.5">
            <span class="font-mono text-base-content/70">{short_url(@agents.url)}</span>
            <.copy_text id="mcp-panel-url" text={@agents.url} label="Copy MCP URL" icon_only />
          </span>
        </div>

        <ul :if={@agents.connected != []} id="mcp-panel-connected" class="flex flex-col gap-2">
          <li
            :for={agent <- @agents.connected}
            id={"mcp-panel-connected-#{agent_key(agent)}"}
            class="flex items-center gap-2.5"
          >
            <.agent_logo id={agent.id} />
            <div class="min-w-0 flex-1">
              <div class="truncate text-sm font-medium">
                {agent.name}
                <span class="font-mono text-base-content/70 font-normal">
                  {client_label(agent.connection)}
                </span>
              </div>
              <div class="font-mono text-base-content/70">{last_call(agent.connection)}</div>
            </div>
          </li>
        </ul>

        <div :if={@agents.connected == []} class="flex flex-col gap-2">
          <p class="text-base-content/70">
            No agent has connected yet.{if @agents.agents != [], do: " Found on this machine:"}
          </p>
          <ul id="mcp-panel-agents" class="flex flex-col">
            <li
              :for={agent <- @agents.agents}
              id={"mcp-panel-agent-#{agent_key(agent)}"}
              class="flex items-center gap-2.5 py-1"
            >
              <.agent_logo id={agent.id} />
              <span class="flex-1 truncate text-sm">{agent.name}</span>
              <span :if={agent.added?} class="badge badge-ghost badge-sm">Added</span>
              <a
                :if={not agent.added? and agent.link}
                id={"mcp-panel-agent-#{agent_key(agent)}-add"}
                href={agent.link}
                class="btn btn-primary btn-xs"
              >
                Add to {agent.name}
              </a>
              <.copy_text
                :if={not agent.added? and agent.command}
                id={"mcp-panel-agent-#{agent_key(agent)}-copy"}
                text={agent.command}
                label="Copy command"
              />
            </li>
            <li id="mcp-panel-agent-other" class="flex items-center gap-2.5 py-1">
              <.agent_logo />
              <span class="flex-1 truncate text-sm">Another agent</span>
              <.copy_text
                id="mcp-panel-setup-prompt"
                text={McpClients.setup_prompt(@agents.url)}
                label="Copy setup prompt"
              />
            </li>
          </ul>
        </div>

        <div class="border-base-content/10 border-t"></div>
        <div class="flex items-center justify-between">
          <a
            href={docs_url()}
            target="_blank"
            rel="noopener noreferrer"
            class="text-primary hover:underline"
          >
            What can agents do?
          </a>
          <.link href={@settings_path} class="text-base-content/70 hover:text-base-content">
            MCP settings
          </.link>
        </div>
      </div>
    </div>
    """
  end

  @spec agent_key(McpAgents.agent()) :: atom() | non_neg_integer()
  def agent_key(%{id: nil, name: name}), do: :erlang.phash2(name)
  def agent_key(%{id: id}), do: id

  @spec client_label(McpAgents.connection()) :: String.t()
  def client_label(%{client: client, version: nil}), do: client
  def client_label(%{client: client, version: version}), do: "#{client} #{version}"

  @spec last_call(McpAgents.connection()) :: String.t()
  def last_call(%{last_seen: last_seen}) do
    case DateTime.diff(DateTime.utc_now(), last_seen) do
      seconds when seconds < 60 -> "last call just now"
      seconds -> "last call #{div(seconds, 60)} min ago"
    end
  end

  defp headline([]), do: "MCP server running"
  defp headline([_agent]), do: "1 agent connected"
  defp headline(connected), do: "#{length(connected)} agents connected"

  defp short_url(url) do
    uri = URI.parse(url)
    ":#{uri.port}#{uri.path}"
  end

  defp logo_tile(:claude_code), do: "bg-brand-claude text-white"
  defp logo_tile(id) when id in [:codex, :cursor], do: "bg-base-content text-base-100"
  defp logo_tile(:gemini), do: "bg-base-100 border-base-300 border"
  defp logo_tile(_id), do: "bg-base-300 text-base-content"

  defp logo_icon(:claude_code), do: "icon-brand-claude"
  defp logo_icon(:codex), do: "icon-brand-openai"
  defp logo_icon(:gemini), do: "icon-brand-gemini"
  defp logo_icon(:cursor), do: "icon-brand-cursor"
  defp logo_icon(_id), do: "icon-bot"
end
