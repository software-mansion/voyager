defmodule Voyager.E2E.TreeHelpers do
  @moduledoc false
  import Playwright.Test.Assertions
  import Voyager.E2E.Fixtures

  alias Playwright.Expect
  alias Playwright.Locator
  alias Playwright.Page

  @cy "document.getElementById('supervision-tree-body')?._cy"

  @doc """
  Runs `mock_app_ctl` (or any MFA) on the target node and returns the printed
  result term, e.g. rpc("mock_app_ctl add_child [mock_dyn_sup_a, tmp_a1]").
  """
  def rpc(mfa) do
    {out, 0} =
      System.cmd("erl_call", ["-name", node_name(), "-c", cookie(), "-a", mfa],
        stderr_to_stdout: true
      )

    String.trim(out)
  end

  def rpc_ok(mfa), do: assert(rpc(mfa) == "ok")

  @doc """
  The floating +/- overlay button of a graph node, addressed by its registered
  name or by its key (e.g. "app:mock_app" for application nodes).
  """
  def toggle(page, ref) do
    Page.locator(page, ~s|.cy-toggle[data-name="#{ref}"], .cy-toggle[data-key="#{ref}"]|)
  end

  @doc """
  Snapshot of a graph node's state, read from the cytoscape instance the hook
  exposes on #supervision-tree-body.
  """
  def cy_node(page, ref) do
    Page.evaluate!(
      page,
      """
      (ref) => {
        const cy = #{@cy};
        if (!cy) return { exists: false };

        const hit = cy
          .nodes()
          .filter((x) => x.id() === ref || String(x.data('name')) === ref);

        return hit.length
          ? {
              exists: true,
              hidden: hit[0].hasClass('hidden'),
              isCollapsed: !!hit[0].data('is_collapsed'),
              childCount: hit[0].data('child_count'),
              hiddenCount: hit[0].data('hidden_count') ?? 0,
              label: String(hit[0].data('displayLabel')),
            }
          : { exists: false };
      }
      """,
      ref
    )
  end

  @doc "The graph key (cytoscape id) of a node, looked up by id or registered name."
  def node_key(page, ref) do
    Page.evaluate!(
      page,
      """
      (ref) => {
        const cy = #{@cy};
        const hit = cy
          ?.nodes()
          .filter((x) => x.id() === ref || String(x.data('name')) === ref);
        return hit?.length ? hit[0].id() : null;
      }
      """,
      ref
    )
  end

  @doc """
  Whether a relationship edge (link / monitor / monitored_by) of the given kind
  connects the two named nodes, in either direction.
  """
  def rel_edge(page, from_ref, to_ref, kind) do
    Page.evaluate!(
      page,
      """
      ({ fromRef, toRef, kind }) => {
        const cy = #{@cy};
        if (!cy) return false;

        const idOf = (ref) => {
          const hit = cy
            .nodes()
            .filter((x) => x.id() === ref || String(x.data('name')) === ref);
          return hit.length ? hit[0].id() : null;
        };

        const a = idOf(fromRef);
        const b = idOf(toRef);

        if (!a || !b) return false;

        return cy.edges().some((e) => {
          const s = e.source().id();
          const t = e.target().id();
          return (
            e.data('kind') === kind &&
            ((s === a && t === b) || (s === b && t === a))
          );
        });
      }
      """,
      %{"fromRef" => from_ref, "toRef" => to_ref, "kind" => kind}
    )
  end

  @doc """
  Names of nodes that are "floating": visible in the graph yet have no visible
  neighbour (every connected node is hidden).
  """
  def floating_nodes(page) do
    Page.evaluate!(page, """
    () => {
      const cy = #{@cy};
      if (!cy) return [];

      const out = [];

      cy.nodes().forEach((n) => {
        if (n.hasClass('hidden')) return;
        const visibleNeighbors = n
          .connectedEdges()
          .connectedNodes()
          .filter((m) => m.id() !== n.id() && !m.hasClass('hidden')).length;
        if (visibleNeighbors === 0) out.push(String(n.data('name')));
      });

      return out;
    }
    """)
  end

  @doc """
  Opens the supervision tree page, selects mock_app and waits until the graph
  has rendered and overlay buttons are in place.
  """
  def open_tree(page) do
    ensure_connected(page)

    Expect.to_pass!(fn ->
      Page.goto!(page, "/node/#{node_name()}/supervision-tree")

      page
      |> Page.locator(~s|input[name="tree_controls[apps][]"][value="mock_app"]|)
      |> Locator.check!()

      Expect.to_have_text!(Page.locator(page, sel(:st_status)), "ok", timeout: 1_000)
      Expect.to_be_visible!(Page.locator(page, sel(:st_body)))
      Expect.to_be_visible!(toggle(page, "mock_deep_sup_1"))
    end)
  end

  @doc """
  Centers the graph viewport on a node at a zoom high enough for overlay
  buttons to exist. Returns false if the node isn't (visibly) in the graph.
  """
  def focus_node(page, ref) do
    Page.evaluate!(
      page,
      """
      (ref) => {
        const cy = #{@cy};
        if (!cy) return false;

        const node = cy
          .nodes()
          .filter((x) => x.id() === ref || String(x.data('name')) === ref);

        if (!node.length || node.hasClass('hidden')) return false;
        if (cy.zoom() < 0.6) cy.zoom(0.6);
        cy.center(node);
        return true;
      }
      """,
      ref
    )
  end

  @doc "Clicks a node's overlay toggle and waits for its collapsed state to flip."
  def click_toggle(page, ref) do
    assert focus_node(page, ref) == true

    btn = toggle(page, ref)
    before = Locator.get_attribute!(btn, "data-collapsed", timeout: 2_000)
    after_state = if before == "true", do: "false", else: "true"

    Expect.to_pass!(
      fn ->
        if not Locator.is_visible!(btn), do: assert(focus_node(page, ref) == true)

        if Locator.get_attribute!(btn, "data-collapsed", timeout: 1_000) != after_state do
          Locator.click!(btn)
        end

        Expect.to_have_attribute!(btn, "data-collapsed", after_state, timeout: 1_000)
      end,
      timeout: 4_000
    )
  end

  @doc "Nudges a refresh, then polls the given assertion."
  def refreshed(page, assertion) do
    Locator.click!(Page.locator(page, sel(:st_refresh)))
    Expect.to_pass!(assertion, timeout: 2_000)
  end

  @doc "Selects a graph node by emitting cytoscape's `onetap`."
  def select_node(page, ref) do
    ok =
      Page.evaluate!(
        page,
        """
        (n) => {
          const cy = #{@cy};
          if (!cy) return false;
          const hit = cy
            .nodes()
            .filter((x) => x.id() === n || String(x.data('name')) === n);
          if (!hit.length || hit.hasClass('hidden')) return false;
          hit[0].emit('onetap');
          return true;
        }
        """,
        ref
      )

    assert ok == true
  end

  @doc "Clears the current selection by emitting a background `tap` on the cytoscape core."
  def clear_selection(page) do
    ok =
      Page.evaluate!(page, """
      () => {
        const cy = #{@cy};
        if (!cy) return false;
        cy.emit('tap');
        return true;
      }
      """)

    assert ok == true
  end

  @doc "CSS `--details-panel-width` in px (what DetailsPanelResize writes)."
  def details_panel_css_width(page) do
    page
    |> Page.locator("#details-panel")
    |> Locator.evaluate!(
      "(el) => Number.parseFloat(getComputedStyle(el).getPropertyValue('--details-panel-width'))"
    )
  end

  @doc "Drags the details panel resize handle left by `delta_px` (grows the panel)."
  def resize_details_panel(page, delta_px) do
    Page.evaluate!(
      page,
      """
      (delta) => {
        const handle = document.getElementById('details-panel-resize-handle');
        if (!handle) throw new Error('resize handle missing');

        const rect = handle.getBoundingClientRect();
        const startX = rect.left + rect.width / 2;
        const y = rect.top + rect.height / 2;

        const fire = (target, type, clientX) => {
          target.dispatchEvent(
            new PointerEvent(type, {
              bubbles: true,
              cancelable: true,
              clientX,
              clientY: y,
              button: 0,
              buttons: type === 'pointerup' || type === 'pointercancel' ? 0 : 1,
              pointerId: 1,
              pointerType: 'mouse',
              isPrimary: true,
            })
          );
        };

        fire(handle, 'pointerdown', startX);
        fire(document, 'pointermove', startX - delta);
        fire(document, 'pointerup', startX - delta);
      }
      """,
      delta_px
    )
  end
end
