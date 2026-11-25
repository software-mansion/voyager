defmodule VoyagerWeb.McpComponents do
  @moduledoc false

  use VoyagerWeb, :component

  alias Voyager.Services.McpAgents

  attr :id, :atom,
    default: nil,
    doc: "a `Voyager.Services.CodingAgents.id()`, nil for any other agent"

  attr :size, :atom, default: :sm, values: [:sm, :md]
  attr :active, :boolean, default: false, doc: "whether the agent has Voyager set up"

  def agent_logo(assigns) do
    ~H"""
    <span class={[
      "flex shrink-0 items-center justify-center transition-colors duration-200",
      if(@size == :md, do: "size-8 rounded-lg", else: "size-6 rounded-md"),
      if(@active,
        do: ["ring-black/10 bg-white shadow-sm ring-1", logo_color(@id)],
        else: "bg-base-200 text-base-content/40"
      )
    ]}>
      <.icon name={logo_icon(@id)} class={if @size == :md, do: "size-4", else: "size-3.5"} />
    </span>
    """
  end

  attr :agents, McpAgents, required: true

  def status_dot(assigns) do
    ~H"""
    <span class={["size-1.5 inline-flex shrink-0 rounded-full", status_color(@agents)]}></span>
    """
  end

  def recently_used(assigns) do
    ~H"""
    <span class="text-success flex items-center gap-1 text-xs font-medium">
      <span class="bg-success size-1.5 rounded-full"></span> Recently used
    </span>
    """
  end

  @spec short_url(String.t()) :: String.t()
  def short_url(url) do
    uri = URI.parse(url)
    ":#{uri.port}#{uri.path}"
  end

  defp status_color(%McpAgents{server: %{alive?: false}}), do: "bg-error"
  defp status_color(%McpAgents{recent: []}), do: "bg-warning"
  defp status_color(%McpAgents{}), do: "bg-success"

  defp logo_color(:claude_code), do: "text-brand-claude"
  defp logo_color(:vscode), do: "text-brand-vscode"
  defp logo_color(:antigravity), do: "text-brand-antigravity"
  defp logo_color(:zed), do: "text-brand-zed"
  defp logo_color(_id), do: "text-black"

  defp logo_icon(:claude_code), do: "icon-brand-claude"
  defp logo_icon(:cursor), do: "icon-brand-cursor"
  defp logo_icon(:vscode), do: "icon-brand-vscode"
  defp logo_icon(:copilot), do: "icon-brand-copilot"
  defp logo_icon(:antigravity), do: "icon-brand-antigravity"
  defp logo_icon(:opencode), do: "icon-brand-opencode"
  defp logo_icon(:codex), do: "icon-brand-openai"
  defp logo_icon(:zed), do: "icon-brand-zed"
  defp logo_icon(_id), do: "icon-bot"
end
