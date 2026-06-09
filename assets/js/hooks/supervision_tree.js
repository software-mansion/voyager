import cytoscape from 'cytoscape';
import dagre from 'cytoscape-dagre';

import {
  LAYOUT_DEBOUNCE_MS,
  OVERLAY_DEBOUNCE_MS,
  OVERLAY_MIN_ZOOM,
  TOPOLOGY_FIELDS,
} from './supervision_tree/constants';
import { buildStyle, toggleIcon, getColor } from './supervision_tree/styles';
import {
  elementsFor,
  composeLabel,
  edgeId,
  isRealPid,
  nodeIntersectsExtent,
} from './supervision_tree/elements';

cytoscape.use(dagre);

const SupervisionTree = {
  mounted() {
    this.container = this.el.querySelector('[data-cy-container]');
    this.overlayLayer = this.el.querySelector('[data-cy-overlays]');

    this.tokens = this.readTokens();
    this.cy = cytoscape({
      container: this.container,
      elements: [],
      style: buildStyle(this.tokens),
      wheelSensitivity: 0.2,
      minZoom: 0.1,
      maxZoom: 2.5,
      autoungrabify: true,
    });

    this.layoutTimer = null;
    this.overlayTimer = null;
    this.overlays = new Map();
    this.fadeTimers = new Map();
    this.disabledClick = false;

    this.cy.on('oneclick', 'node', (e) => {
      if (this.disabledClick) return;
      this.pushEventTo(this.el, 'select-node', { key: e.target.id() });
    });
    this.cy.on('dblclick', 'node', (e) => {
      if (this.disabledClick) return;
      this.toggleExpandNode(e.target);
    });
    this.cy.on('tap', (e) => {
      if (this.disabledClick) return;
      if (e.target === this.cy)
        this.pushEventTo(this.el, 'select-node', { key: '' });
    });

    // Change the cursor to a pointer when hovering over a node
    this.cy.on('mouseover', 'node', function (event) {
      event.target.addClass('hover');
      event.cy.container().style.cursor = 'pointer';
    });

    // Revert the cursor to default when the mouse leaves the node
    this.cy.on('mouseout', 'node', function (event) {
      event.target.removeClass('hover');
      event.cy.container().style.cursor = '';
    });

    this.cy.on('viewport', () => {
      this.repositionOverlays();
      this.scheduleOverlayReconcile();
    });
    this.cy.on('render', () => this.repositionOverlays());

    this.handleEvent('tree-data', (p) => this.applyPayload(p));
    this.handleEvent('path-highlight', (p) => this.applyHighlight(p));

    this.themeObserver = new MutationObserver(() => this.refreshTokens());
    this.themeObserver.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ['data-theme', 'class'],
    });
  },

  destroyed() {
    this.tearDownAllOverlays();
    for (const t of this.fadeTimers.values()) clearTimeout(t);
    this.fadeTimers.clear();
    if (this.layoutTimer) clearTimeout(this.layoutTimer);
    if (this.overlayTimer) clearTimeout(this.overlayTimer);
    if (this.themeObserver) this.themeObserver.disconnect();
    if (this.cy) this.cy.destroy();
  },

  // ---------------------------------------------------------------------------
  // Payload application
  // ---------------------------------------------------------------------------

  applyPayload(payload) {
    if (!payload) return;

    if (payload.kind === 'full') {
      this.applyFull(payload);
    } else if (payload.kind === 'delta') {
      this.applyDelta(payload);
    }
  },

  applyFull(payload) {
    const incoming = payload.nodes || {};

    this.cy.batch(() => {
      this.tearDownAllOverlays();
      this.cy.elements().remove();

      const addBatch = [];
      for (const [key, node] of Object.entries(incoming)) {
        addBatch.push(...elementsFor(key, node));
      }
      this.cy.add(addBatch);
    });

    this.runLayout({ fit: true });
    this.scheduleOverlayReconcile();
  },

  applyDelta(payload) {
    const removed = payload.removed || [];
    const added = payload.added || {};
    const updated = payload.updated || {};

    let topologyChanged = false;

    this.cy.batch(() => {
      // Removals
      for (const key of removed) {
        const el = this.cy.getElementById(key);
        if (el.nonempty()) {
          el.connectedEdges().remove();
          el.remove();
          this.tearDownOverlay(key);
          topologyChanged = true;
        }
      }

      // Additions
      for (const [key, node] of Object.entries(added)) {
        this.cy.add(elementsFor(key, node));
        topologyChanged = true;
      }

      // Updates
      for (const [key, patch] of Object.entries(updated)) {
        const node = this.cy.getElementById(key);
        if (node.empty()) continue;

        for (const [field, value] of Object.entries(patch)) {
          if (field === 'parent_key') {
            // edge re-parent
            node.connectedEdges('[target = "' + key + '"]').remove();
            if (value) {
              this.cy.add({
                group: 'edges',
                data: { id: edgeId(value, key), source: value, target: key },
              });
            }
            topologyChanged = true;
          } else {
            node.data(field, value);
          }

          if (TOPOLOGY_FIELDS.has(field)) topologyChanged = true;
        }

        // Rebuild displayLabel if name or child_count moved.
        if (patch.name !== undefined || patch.child_count !== undefined) {
          node.data('displayLabel', composeLabel(node.data()));
        }

        // Dead state.
        if (patch.info !== undefined) {
          node.data('dead', patch.info === 'dead');
        }
      }
    });

    if (topologyChanged) {
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
      animate: !fit,
      animationDuration: 280,
      animationEasing: 'ease-out',
      fit,
      padding: 24,
      nodeDimensionsIncludeLabels: true,
    });

    layout.on('layoutstop', () => {
      this.cy.style().update();
      this.disabledClick = false;
    });

    this.disabledClick = true;

    layout.run();
  },

  scheduleLayout() {
    if (this.layoutTimer) clearTimeout(this.layoutTimer);
    this.layoutTimer = setTimeout(() => {
      this.layoutTimer = null;
      this.runLayout({ fit: false });
      this.scheduleOverlayReconcile();
    }, LAYOUT_DEBOUNCE_MS);
  },

  applyHighlight({ path }) {
    this.cy.batch(() => {
      this.cy.elements().removeClass('in-path');
      if (!path || path.length === 0) return;

      const nodeColl = this.cy.collection(
        path.map((k) => this.cy.getElementById(k)).filter((n) => n.nonempty())
      );
      if (nodeColl.empty()) return;

      const edgeColl = nodeColl.connectedEdges().filter((edge) => {
        return (
          nodeColl.contains(edge.source()) && nodeColl.contains(edge.target())
        );
      });

      nodeColl.union(edgeColl).addClass('in-path');
    });
  },

  toggleExpandNode(node) {
    this.disabledClick = true;
    if (isRealPid(node.id())) {
      this.pushEventTo(this.el, 'toggle-expand', { pid: node.id() });
    }

    this.cy.batch(() => {
      if (this.isCollapsed(node)) {
        node.data('is_collapsed', false);
        node.successors().forEach((ele) => {
          const hidden_count = ele.data('hidden_count') ?? 0;
          ele.data('hidden_count', Math.max(hidden_count - 1, 0));
        });
        node.successors('[hidden_count = 0]').removeClass('hidden');
      } else {
        node.data('is_collapsed', true);
        node.successors().forEach((ele) => {
          const hidden_count = ele.data('hidden_count') ?? 0;
          ele.data('hidden_count', hidden_count + 1);
        });
        node.successors().addClass('hidden');
      }
    });

    this.scheduleLayout();
  },

  // ---------------------------------------------------------------------------
  // Overlays
  // ---------------------------------------------------------------------------

  scheduleOverlayReconcile() {
    if (this.overlayTimer) clearTimeout(this.overlayTimer);
    this.overlayTimer = setTimeout(() => {
      this.overlayTimer = null;
      this.reconcileOverlays();
    }, OVERLAY_DEBOUNCE_MS);
  },

  reconcileOverlays() {
    if (!this.cy) return;

    const tooSmall = this.cy.zoom() < OVERLAY_MIN_ZOOM;
    const extent = this.cy.extent();

    const wanted = new Set();

    if (!tooSmall) {
      this.cy.nodes('[?has_children]').forEach((node) => {
        if (nodeIntersectsExtent(node, extent)) {
          wanted.add(node.id());
        }
      });
    }

    // Tear down ones no longer needed.
    for (const key of [...this.overlays.keys()]) {
      if (!wanted.has(key)) this.tearDownOverlay(key);
    }

    // Create new ones.
    for (const key of wanted) {
      if (!this.overlays.has(key)) {
        this.createOverlay(this.cy.getElementById(key));
      }
    }
  },

  createOverlay(node) {
    if (node.empty()) return;
    const key = node.id();

    const dom = document.createElement('button');
    dom.type = 'button';
    dom.className = 'cy-toggle';
    dom.dataset.key = key;
    dom.innerHTML = toggleIcon(this.isCollapsed(node));
    dom.addEventListener('click', (ev) => {
      if (this.disabledClick) return;
      ev.stopPropagation();
      this.toggleExpandNode(node);
    });

    this.overlayLayer.appendChild(dom);
    this.overlays.set(key, { dom });
    this.positionOverlay(key);
  },

  positionOverlay(key) {
    const entry = this.overlays.get(key);
    if (!entry) return;
    const node = this.cy.getElementById(key);
    if (node.empty()) return;
    if (node.classNames().includes('hidden')) {
      entry.dom.style.display = 'none';
      return;
    }
    entry.dom.style.display = '';

    const bb = node.renderedBoundingBox();
    // Anchor at the right edge of the rendered label.
    const x = bb.x2 + 10;
    const y = (bb.y1 + bb.y2) / 2 - 11;
    entry.dom.style.transform = `translate(${x}px, ${y}px)`;

    // Keep icon in sync with collapsed state.
    const collapsed = this.isCollapsed(node);
    if (entry.collapsed !== collapsed) {
      entry.dom.innerHTML = toggleIcon(collapsed);
      entry.collapsed = collapsed;
    }
  },

  repositionOverlays() {
    for (const key of this.overlays.keys()) this.positionOverlay(key);
  },

  tearDownOverlay(key) {
    const entry = this.overlays.get(key);
    if (!entry) return;
    entry.dom.remove();
    this.overlays.delete(key);
  },

  tearDownAllOverlays() {
    for (const key of [...this.overlays.keys()]) this.tearDownOverlay(key);
  },

  isCollapsed(node) {
    return node.data('is_collapsed');
  },

  readTokens() {
    const cs = getComputedStyle(this.el);
    return {
      base100: getColor(cs, '--color-base-100', '#ffffff'),
      base500: getColor(cs, '--color-base-500', '#CAD5E2'),
      baseContent: getColor(cs, '--color-base-content', '#1a1a1a'),
      primary: getColor(cs, '--color-primary', '#3b82f6'),
      error: getColor(cs, '--color-error', '#ef4444'),
    };
  },

  refreshTokens() {
    this.tokens = this.readTokens();
    this.cy.style(buildStyle(this.tokens));
  },
};

export default SupervisionTree;
