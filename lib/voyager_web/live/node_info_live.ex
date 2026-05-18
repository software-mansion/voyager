defmodule VoyagerWeb.NodeInfoLive do
  use VoyagerWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, assign(socket, :active_nav, :node_info)}
  end

  defp language_name(nil), do: "detecting..."
  defp language_name(lang), do: lang.name()

  def render(assigns) do
    ~H"""
    <div style="padding: 1rem; font-family: monospace;">
      <p><strong>Node:</strong> {@session.node_name}</p>
      <p><strong>Language:</strong> {language_name(@session.language)}</p>
      <p><strong>Connected at:</strong> {@session.connected_at}</p>
      <hr />
      <pre>{inspect(@session.info, pretty: true, limit: :infinity)}</pre>
    </div>
    """
  end
end
