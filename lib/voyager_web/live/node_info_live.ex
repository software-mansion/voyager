defmodule VoyagerWeb.NodeInfoLive do
  use VoyagerWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:active_nav, :node_info)
     |> assign(:otp_release, fetch_otp_release(socket.assigns.session.node))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-4xl p-8">
      <h1 class="font-mono text-base-content mb-8 text-2xl font-bold tracking-tight">
        {@session.node_name}
      </h1>

      <.info_card label="OTP" value={format_otp_release(@otp_release)} data-testid="otp-card" />
    </div>
    """
  end

  defp fetch_otp_release(node) do
    # This call should not be here, it's temporary just for showing that Node is connected properly
    # We will move communication with a node to Node session probably in the future
    :erpc.call(node, :erlang, :system_info, [:otp_release])
  catch
    :error, _ -> nil
  end

  defp format_otp_release(nil), do: "—"
  defp format_otp_release(release), do: to_string(release)
end
