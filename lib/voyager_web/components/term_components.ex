defmodule VoyagerWeb.Components.TermComponents do
  @moduledoc """
  Renders an Elixir term as a collapsible tree.

  Only the open parts of the term are turned into markup, so pointing this at a
  large term is cheap until the user asks to see more of it. Which parts are
  open lives in a `VoyagerWeb.TermTree.State` held by the caller;
  `VoyagerWeb.Hooks.TermTreeHook` keeps one per inspector and answers the
  toggle events, so a LiveView using the hook needs no event handlers of its
  own.
  """

  use VoyagerWeb, :component

  alias VoyagerWeb.TermTree
  alias VoyagerWeb.TermTree.Segment
  alias VoyagerWeb.TermTree.State

  @doc """
  Renders `term` as an expandable tree.

  A collection the remote node cut short is flagged on itself, so a truncated
  branch can be spotted without opening it. A shortened binary carries no such
  trace and is not flagged.
  """
  attr :id, :string, required: true
  attr :term, :any, required: true
  attr :state, State, required: true
  attr :toggle_event, :string, default: "term-toggle"
  attr :window_event, :string, default: "term-window"
  attr :class, :any, default: nil

  def term_inspector(assigns) do
    assigns = assign(assigns, :node, TermTree.describe(assigns.term))

    ~H"""
    <div id={@id} class={["font-mono text-xs" | List.wrap(@class)]}>
      <.term_node
        id={@id}
        term={@term}
        node={@node}
        state={@state}
        toggle_event={@toggle_event}
        window_event={@window_event}
      />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :term, :any, required: true
  attr :node, TermTree.Node, required: true
  attr :state, State, required: true
  attr :toggle_event, :string, required: true
  attr :window_event, :string, required: true

  defp term_node(assigns) do
    node = assigns.node
    open? = TermTree.Node.expandable?(node) and TermTree.open?(assigns.state, node.path)
    children = if open?, do: child_nodes(assigns.term, node, assigns.state), else: []

    assigns =
      assigns
      |> assign(:expandable?, TermTree.Node.expandable?(node))
      |> assign(:open?, open?)
      |> assign(:children, children)
      |> assign(:remaining, node.child_count - length(children))
      |> assign(:node_id, dom_id(assigns.id, node.path))
      |> assign(:encoded_path, TermTree.encode_path(node.path))

    ~H"""
    <div class="flex flex-col">
      <%= if @expandable? do %>
        <.collapsible
          open={@open?}
          label_class="max-w-max"
          chevron_class="term-chevron text-code-punct"
          id={@node_id <> "-toggle"}
          phx-click={@toggle_event}
          phx-value-id={@id}
          phx-value-path={@encoded_path}
        >
          <:label :let={open}>
            <.segments items={if(open, do: @node.expanded_before, else: @node.content)} />
          </:label>
          <:right>
            <.truncation_mark :if={@node.truncated?} id={@node_id} />
          </:right>
          <ol :if={@open?} class="term-indent m-0 block list-none p-0">
            <li :for={{child_term, child_node} <- @children} id={dom_id(@id, child_node.path)}>
              <.term_node
                id={@id}
                term={child_term}
                node={child_node}
                state={@state}
                toggle_event={@toggle_event}
                window_event={@window_event}
              />
            </li>
          </ol>
          <button
            :if={@open? and @remaining > 0}
            type="button"
            id={@node_id <> "-more"}
            phx-click={@window_event}
            phx-value-id={@id}
            phx-value-path={@encoded_path}
            class="term-indent link link-hover text-code-punct max-w-max"
          >
            +{@remaining} more
          </button>
          <div :if={@open?} class="term-indent">
            <.segments items={@node.expanded_after} />
          </div>
        </.collapsible>
      <% else %>
        <div class="term-indent">
          <.segments items={@node.content} />
        </div>
      <% end %>
    </div>
    """
  end

  attr :id, :string, required: true

  defp truncation_mark(assigns) do
    ~H"""
    <.tooltip id={"#{@id}-truncated"} class="text-warning ml-1.5 self-center">
      <span
        tabindex="0"
        role="img"
        aria-label="Truncated on the remote node - some values are not shown."
        class="inline-flex"
      >
        <.icon name="icon-circle-alert" class="size-3.5" />
      </span>
      <:content>
        Truncated on the remote node - some values are not shown.
      </:content>
    </.tooltip>
    """
  end

  attr :items, :list, required: true

  defp segments(assigns) do
    ~H"""
    <span class="flex whitespace-pre">
      <span :for={item <- @items} class={segment_class(item)}>{item.text}</span>
    </span>
    """
  end

  defp child_nodes(term, node, state) do
    last_index = node.child_count - 1

    term
    |> TermTree.children(0, TermTree.window(state, node.path))
    |> Enum.with_index()
    |> Enum.map(fn {{key, child}, index} ->
      child_node =
        TermTree.describe(child,
          path: node.path ++ [index],
          key: key,
          comma?: index < last_index
        )

      {child, child_node}
    end)
  end

  defp segment_class(%Segment{kind: :atom}), do: "text-code-atom"
  defp segment_class(%Segment{kind: :module}), do: "text-code-atom"
  defp segment_class(%Segment{kind: :number}), do: "text-code-number"
  defp segment_class(%Segment{kind: :string}), do: "text-code-string"
  defp segment_class(%Segment{kind: :special}), do: "text-code-special"
  defp segment_class(%Segment{kind: :muted}), do: "text-code-punct opacity-70"
  defp segment_class(%Segment{}), do: "text-code-punct"

  defp dom_id(id, []), do: "#{id}-root"
  defp dom_id(id, path), do: "#{id}-#{Enum.join(path, "-")}"
end
