defmodule VoyagerWeb.Hooks.TermTreeHook do
  @moduledoc """
  Answers the expand/collapse events of
  `VoyagerWeb.Components.TermComponents.term_inspector/1`.

  Holds one `VoyagerWeb.TermTree.State` per inspector under `:term_states`, so
  a page can render several inspectors while the LiveView itself handles none
  of their events. Call `put_term/3` whenever the displayed term is assigned;
  it seeds the state with a sensible set of open branches and drops whatever
  the previous term had expanded.
  """

  import Phoenix.Component
  import Phoenix.LiveView

  alias Phoenix.LiveView.Socket
  alias VoyagerWeb.TermTree

  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> assign(:term_states, %{})
      |> attach_hook(:term_tree, :handle_event, &handle_event/3)

    {:cont, socket}
  end

  @doc """
  Seeds the expansion state for the inspector rendered under `id`.
  """
  @spec put_term(Socket.t(), String.t(), term()) :: Socket.t()
  def put_term(socket, id, term) do
    update(socket, :term_states, &Map.put(&1, id, TermTree.initial_state(term)))
  end

  defp handle_event("term-toggle", %{"id" => id, "path" => path}, socket) do
    {:halt, update_state(socket, id, path, &TermTree.toggle/2)}
  end

  defp handle_event("term-window", %{"id" => id, "path" => path}, socket) do
    {:halt, update_state(socket, id, path, &TermTree.expand_window/2)}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp update_state(socket, id, encoded_path, fun) do
    with {:ok, path} <- TermTree.decode_path(encoded_path),
         {:ok, state} <- Map.fetch(socket.assigns.term_states, id) do
      update(socket, :term_states, &Map.put(&1, id, fun.(state, path)))
    else
      _ -> socket
    end
  end
end
