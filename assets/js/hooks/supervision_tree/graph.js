import { TOPOLOGY_FIELDS, LAYOUT_DEBOUNCE_MS } from './constants';
import {
  elementsFor,
  relEdgeElement,
  composeLabel,
  isRealPid,
  initialIsCollapsedState,
  edgeElement,
} from './elements';
import { buildStyle, getColor } from './styles';

/**
 * @import {ServerNode, ServerEdge, Info} from './elements.js'
 */

/**
 * Graph manipulation: applying server payloads, running the dagre layout,
 * highlighting edges/paths, expand/collapse, zoom, and theme tokens.
 *
 * These are mixed onto the SupervisionTree hook, so `this` is the hook instance
 * and shares state (`this.cy`, `this.disabledClick`, timers, …) with the
 * overlay and tooltip mixins.
 */
export const graphMethods = {
  /** @type {ReturnType<typeof setTimeout> | undefined} */
  layoutTimer: undefined,
  /** @type {string | null} */ selectedEdgeId: null,
  /** @type {string[] | null} */ selectedPath: null,

  initGraph() {
    /** @type {HTMLMetaElement | null} */
    const metaEnv = document.querySelector('meta[name="env"]');

    this.animate = metaEnv?.content !== 'e2e';
  },

  cleanupGraph() {
    clearTimeout(this.layoutTimer);
  },

  // ---------------------------------------------------------------------------
  // Payload application
  // ---------------------------------------------------------------------------

  /**
   * @typedef {Object} FullPayload
   * @property {'full'} kind
   * @property {'initial' | 'auto_refresh' | 'manual_refresh' | 'toggle_expand'} request_type
   * @property {Record<string, ServerNode>} nodes
   * @property {Record<string, ServerEdge>} edges
   *
   * @typedef {Object} Patch
   * @property {string} name
   * @property {string | null} parent_key
   * @property {'app' | 'supervisor' | 'worker' | 'port' | 'reference'} type
   * @property {number} child_count
   * @property {Info | 'dead' | null} info
   * @property {string[] | 'not_loaded'} children_keys
   *
   * @typedef {Object} DeltaPayload
   * @property {'delta'} kind
   * @property {'initial' | 'auto_refresh' | 'manual_refresh' | 'toggle_expand'} request_type
   * @property {Record<string, ServerNode>} added
   * @property {string[]} removed
   * @property {Record<string, Patch>} updated
   * @property {Record<string, ServerEdge>} edges_added
   * @property {string[]} edges_removed
   *
   * @param {FullPayload | DeltaPayload} payload
   */
  applyPayload(payload) {
    if (!payload) return;

    if (payload.kind === 'full') {
      this.applyFull(payload);
    } else if (payload.kind === 'delta') {
      this.applyDelta(payload);
    }

    if (this.selectedEdgeId) {
      this.applyEdgeHighlight(this.selectedEdgeId);
    } else if (this.selectedPath) {
      this.applyPathHighlight({ path: this.selectedPath });
    }
  },

  /**
   * @param {FullPayload} payload
   */
  applyFull(payload) {
    const incoming = payload.nodes || {};
    const edges = payload.edges || {};

    this.cy.batch(() => {
      this.tearDownAllOverlays();
      this.cy.elements().remove();

      const addBatch = [];
      for (const [key, node] of Object.entries(incoming)) {
        addBatch.push(...elementsFor(key, node));
      }
      // Relationship edges are appended after all nodes so their endpoints
      // already exist when cytoscape processes the batch.
      for (const edge of Object.values(edges)) {
        addBatch.push(relEdgeElement(edge));
      }
      this.cy.add(addBatch);
    });

    this.runLayout({ fit: true });
    this.scheduleOverlayReconcile();
  },

  /**
   * @param {DeltaPayload} payload
   */
  applyDelta(payload) {
    const removed = payload.removed || [];
    const added = payload.added || {};
    const updated = payload.updated || {};
    const edgesAdded = payload.edges_added || {};
    const edgesRemoved = payload.edges_removed || [];

    let topologyChangeCounter = 0;

    this.cy.batch(() => {
      // Removals
      for (const key of removed) {
        const el = this.cy.getElementById(key);
        if (el.nonempty()) {
          el.connectedEdges().remove();
          el.remove();
          this.tearDownOverlay(key);
          topologyChangeCounter++;
        }
      }

      // Additions
      const addBatch = [];
      for (const [key, node] of Object.entries(added)) {
        addBatch.push(...elementsFor(key, node));
        topologyChangeCounter++;
      }
      this.cy.add(addBatch);

      // Updates
      for (const [key, patch] of Object.entries(updated)) {
        const node = this.cy.getElementById(key);
        if (node.empty()) continue;

        for (const [field, value] of Object.entries(patch)) {
          if (field === 'parent_key') {
            const parent_key = node.data('parent_key');

            node
              .connectedEdges(`[source = "${parent_key}"][target = "${key}"]`)
              .remove();

            if (patch.parent_key) {
              this.cy.add(edgeElement(patch.parent_key, key));
            }

            node.data('is_from_relation', patch.parent_key === null);
          }

          node.data(field, value);

          if (TOPOLOGY_FIELDS.has(field)) topologyChangeCounter++;
        }

        if (patch.name !== undefined || patch.child_count !== undefined) {
          node.data('displayLabel', composeLabel(node.data()));
        }

        if (patch.child_count !== undefined) {
          node.data('is_collapsed', initialIsCollapsedState(node.data()));
        }

        if (patch.info !== undefined) {
          node.data('dead', patch.info === 'dead');
        }
      }

      // Relationship edge removals (node removals above already drop their
      // connected edges, so a missing edge here is a no-op).
      for (const id of edgesRemoved) {
        const el = this.cy.getElementById(id);
        if (el.nonempty()) el.remove();
      }

      // Relationship edge additions — guard that both endpoints exist (their
      // rel-node additions were applied earlier in this batch).
      const edgesAddBatch = [];
      for (const edge of Object.values(edgesAdded)) {
        if (this.cy.getElementById(edge.id).nonempty()) continue;
        const source = this.cy.getElementById(edge.source);
        const target = this.cy.getElementById(edge.target);
        if (source.nonempty() && target.nonempty()) {
          edgesAddBatch.push(relEdgeElement(edge));
          topologyChangeCounter++;
          source.data('hidden_count', 0);
          target.data('hidden_count', 0);
          source.removeClass('hidden');
          target.removeClass('hidden');
        } else {
          console.warn(
            `Failed to add edge. At least one target empty: ${source.id()} - ${target.id()}`
          );
        }
      }
      this.cy.add(edgesAddBatch);
    });

    if (topologyChangeCounter > 4 && payload.request_type !== 'toggle_expand') {
      this.scheduleLayout({ fit: true });
    } else if (topologyChangeCounter > 0) {
      this.scheduleLayout();
    }
  },

  // ---------------------------------------------------------------------------
  // Layout
  // ---------------------------------------------------------------------------

  runLayout({ fit }) {
    if (this.cy.elements().empty()) return;

    const layout = this.cy.layout({
      name: 'dagre',
      rankDir: 'LR',
      ranker: 'tight-tree',
      nodeSep: 14,
      edgeSep: 8,
      rankSep: 180,
      spacingFactor: 1.3,
      animate: this.animate,
      animationDuration: 280,
      animationEasing: 'ease-out',
      fit,
      padding: 45,
      nodeDimensionsIncludeLabels: true,
    });

    layout.on('layoutstop', () => {
      this.cy.style().update();
      this.disabledClick = false;
    });

    this.disabledClick = true;

    layout.run();
  },

  scheduleLayout({ fit = false } = {}) {
    clearTimeout(this.layoutTimer);
    this.layoutTimer = setTimeout(() => {
      this.runLayout({ fit });
      this.scheduleOverlayReconcile();
    }, LAYOUT_DEBOUNCE_MS);
  },

  // ---------------------------------------------------------------------------
  // Selection highlighting
  // ---------------------------------------------------------------------------

  applyPathHighlight({ path }) {
    this.selectedEdgeId = null;
    this.selectedPath = path && path.length > 0 ? path : null;

    this.cy.batch(() => {
      this.cy
        .elements('.selected, .endpoint, .dimmed')
        .removeClass('selected endpoint dimmed');

      if (!this.selectedPath) return;

      const selectedKey = this.selectedPath[this.selectedPath.length - 1];
      if (this.cy.getElementById(selectedKey).empty()) {
        this.selectedPath = null;
        return;
      }

      const nodeColl = this.cy.collection(
        this.selectedPath
          .map((k) => this.cy.getElementById(k))
          .filter((n) => n.nonempty())
      );
      if (nodeColl.empty()) {
        this.selectedPath = null;
        return;
      }

      const edgeColl = nodeColl.connectedEdges().filter((edge) => {
        return (
          nodeColl.contains(edge.source()) && nodeColl.contains(edge.target())
        );
      });

      this.cy.edges().difference(edgeColl).addClass('dimmed');
      edgeColl.addClass('selected');
      nodeColl.addClass('selected');
    });
  },

  selectEdge(edge) {
    const clickedEdgeId = edge.id();
    const nextEdgeId =
      this.selectedEdgeId === clickedEdgeId ? null : clickedEdgeId;

    this.applyEdgeHighlight(nextEdgeId);
  },

  applyEdgeHighlight(edgeId) {
    this.selectedEdgeId = edgeId || null;
    this.selectedPath = null;

    this.cy.batch(() => {
      this.cy
        .elements('.selected, .endpoint, .dimmed')
        .removeClass('selected endpoint dimmed');

      if (!this.selectedEdgeId) return;

      const edge = this.cy.getElementById(this.selectedEdgeId);
      if (edge.empty() || !edge.isEdge()) {
        this.selectedEdgeId = null;
        return;
      }

      this.cy.edges().difference(edge).addClass('dimmed');
      edge.addClass('selected');
      edge.source().union(edge.target()).addClass('endpoint');
    });
  },

  // ---------------------------------------------------------------------------
  // Expand / collapse
  // ---------------------------------------------------------------------------

  isCollapsed(node) {
    return node.data('is_collapsed');
  },

  toggleExpandNode(node) {
    if (node.data('child_count') == 0) return;

    this.disabledClick = true;

    if (isRealPid(node.id())) {
      this.pushEventTo(this.el, 'toggle-expand', { pid: node.id() });
    }

    const bumpHiddenCount = (ele, delta) => {
      const current = ele.data('hidden_count') ?? 0;
      const next = Math.max(current + delta, 0);
      ele.data('hidden_count', next);
      return next;
    };

    this.cy.batch(() => {
      if (this.isCollapsed(node)) {
        // Expand: decrement the hidden_count of every successor, then reveal
        // those no longer hidden by any other collapsed ancestor.
        node.data('is_collapsed', false);

        this.getSupervisionSuccessors(node).forEach((ele) => {
          if (bumpHiddenCount(ele, -1) == 0) {
            ele.removeClass('hidden');
          }
        });

        this.getRelationsSuccessors(node).forEach((ele) => {
          if (bumpHiddenCount(ele, -1) == 0) {
            ele.removeClass('hidden');
          }
        });
      } else {
        // Collapse: hide tree successors outright.
        node.data('is_collapsed', true);

        this.getSupervisionSuccessors(node).forEach((ele) => {
          bumpHiddenCount(ele, 1);
          ele.addClass('hidden');
        });

        // Hide relation successors only once all they have no visible incoming nodes.
        this.getRelationsSuccessors(node).forEach((ele) => {
          const visibleConnectedNodes = ele
            .incomers('node')
            .difference('.hidden');

          if (visibleConnectedNodes.length == 0) {
            bumpHiddenCount(ele, 1);
            ele.addClass('hidden');
          }
        });
      }
    });

    this.scheduleLayout();
  },

  /**
   * Fetches strict supervision tree successors (nodes) of a given node.
   * Omits graph successor branches created by additional process relations (custom link, monitor, monitored_by)
   */
  getSupervisionSuccessors(node) {
    const treeSuccessors = node
      .successors('[!is_from_relation]')
      .union(node)
      .difference('edge[kind!="supervision-link"]')
      .components()
      .filter((eles) => eles.contains(node))[0]
      .nodes();

    // Filter out nodes that have supervision parents outside of collapsing node successors (other applications tree)
    return treeSuccessors.filter((ele) => {
      const sources = ele
        .connectedEdges(`[target="${ele.id()}"][kind="supervision-link"]`)
        .sources();

      if (sources.length == 0) return false;

      return treeSuccessors.contains(sources);
    });
  },

  /**
   * Fetches tree successors (nodes) of a given node that are not strict part of a supervision tree
   * but created by additional relations (custom link, monitor, monitored_by).
   */
  getRelationsSuccessors(node) {
    return node.successors('node[?is_from_relation]');
  },

  zoomBy(factor) {
    const { x1, x2, y1, y2 } = this.cy.extent();
    const x = (x1 + x2) / 2;
    const y = (y1 + y2) / 2;

    this.cy.animate({
      zoom: {
        level: this.cy.zoom() * factor,
        position: { x, y },
      },
      duration: 200,
      queue: false,
    });
  },

  readTokens() {
    const cs = getComputedStyle(this.el);
    return {
      base100: getColor(cs, '--color-base-100', '#ffffff'),
      base400: getColor(cs, '--color-base-400', '#cccccc'),
      base500: getColor(cs, '--color-base-500', '#CAD5E2'),
      baseContent: getColor(cs, '--color-base-content', '#1a1a1a'),
      primary: getColor(cs, '--color-primary', '#3b82f6'),
      secondary: getColor(cs, '--color-secondary', '#3b82f6'),
      port: getColor(cs, '--color-port', '#dddd55'),
      reference: getColor(cs, '--color-success', '#22ee22'),
      processMonitor: getColor(cs, '--color-process-monitor', '#d1a1e5'),
      processMonitoredBy: getColor(
        cs,
        '--color-process-monitored-by',
        '#4db8ff'
      ),
      error: getColor(cs, '--color-error', '#ef4444'),
    };
  },

  refreshTokens() {
    this.tokens = this.readTokens();
    this.cy.style(buildStyle(this.tokens));
  },
};
