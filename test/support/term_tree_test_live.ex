defmodule VoyagerWeb.TermTreeTestLive do
  @moduledoc """
  Host LiveView for the term inspector, mounted with `live_isolated/3`.

  It starts with no term; `send(view.pid, {:put_term, id, term})` renders an
  inspector for that term, which keeps arbitrary terms — pids and refs included
  — out of the session payload. The `#ping` button exists so tests can check
  that events the term hook does not own still reach the LiveView.
  """

  use Phoenix.LiveView

  import VoyagerWeb.Components.TermComponents
  import VoyagerWeb.Helpers

  alias VoyagerWeb.Hooks.TermTreeHook

  on_mount TermTreeHook

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    socket
    |> assign(:terms, [])
    |> assign(:pings, 0)
    |> ok()
  end

  @impl Phoenix.LiveView
  def handle_info({:put_term, id, term}, socket) do
    socket
    |> update(:terms, &List.keystore(&1, id, 0, {id, term}))
    |> TermTreeHook.put_term(id, term)
    |> noreply()
  end

  @impl Phoenix.LiveView
  def handle_event("ping", _params, socket) do
    socket
    |> update(:pings, &(&1 + 1))
    |> noreply()
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div id="host">
      <button type="button" id="ping" phx-click="ping">pings: {@pings}</button>
      <.term_inspector
        :for={{id, term} <- @terms}
        id={id}
        term={term}
        state={@term_states[id]}
      />
    </div>
    """
  end
end
