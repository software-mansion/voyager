import cytoscape from 'cytoscape';
import dagre from 'cytoscape-dagre';
import Color from 'colorjs.io';

cytoscape.use(dagre);

const LAYOUT_DEBOUNCE_MS = 50;
const OVERLAY_DEBOUNCE_MS = 80;
const OVERLAY_MIN_ZOOM = 0.45;
const DBLTAP_GUARD_MS = 250;
const FADE_MS = 200;

const TOPOLOGY_FIELDS = new Set([
  'name',
  'type',
  'has_children?',
  'child_count',
  'children_keys',
  'parent_key',
]);

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
      minZoom: 0.2,
      maxZoom: 2.5,
      boxSelectionEnabled: false,
    });

    this.layoutTimer = null;
    this.overlayTimer = null;
    this.overlays = new Map();
    this.fadeTimers = new Map();
    this.lastTapTs = 0;
    this.lastTapId = null;
    this.pendingSelectTimer = null;

    this.cy.on('tap', 'node', (e) => this.onNodeTap(e));
    this.cy.on('tap', (e) => {
      if (e.target === this.cy) this.onBackgroundTap();
    });

    // Change the cursor to a pointer when hovering over a node
    this.cy.on('mouseover', 'node', function (event) {
      event.target.addClass('hover');
      const container = event.cy.container();
      if (container) {
        container.style.cursor = 'pointer';
      }
    });

    // Revert the cursor to default when the mouse leaves the node
    this.cy.on('mouseout', 'node', function (event) {
      event.target.removeClass('hover');
      const container = event.cy.container();
      if (container) {
        container.style.cursor = '';
      }
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
    if (this.pendingSelectTimer) clearTimeout(this.pendingSelectTimer);
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

    // Detect restart pairs (same parent_key + name, one removed and one added)
    // so we can fade them rather than instant-swap.
    const restartPairs = this.detectRestarts(removed, added);

    let topologyChanged = false;

    this.cy.batch(() => {
      // Removals
      for (const key of removed) {
        if (restartPairs.removedToPair.has(key)) continue; // handle below
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
        if (restartPairs.addedToPair.has(key)) continue;
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

      // Restart pairs: fade-out old, fade-in new.
      for (const [removedKey, addedKey] of restartPairs.pairs) {
        this.applyRestartPair(removedKey, addedKey, added[addedKey]);
        topologyChanged = true;
      }
    });

    if (topologyChanged) {
      this.scheduleLayout();
    }
    this.scheduleOverlayReconcile();
  },

  // ---------------------------------------------------------------------------
  // Restart detection / fade
  // ---------------------------------------------------------------------------

  detectRestarts(removed, added) {
    // Group existing-soon-to-be-removed nodes by parent_key + name
    const removedByPair = new Map();
    for (const key of removed) {
      const el = this.cy.getElementById(key);
      if (el.empty()) continue;
      const d = el.data();
      const pairKey = pairSignature(d.parent_key, d.name);
      if (!removedByPair.has(pairKey)) removedByPair.set(pairKey, []);
      removedByPair.get(pairKey).push(key);
    }

    const pairs = [];
    const removedToPair = new Set();
    const addedToPair = new Set();

    for (const [addedKey, node] of Object.entries(added)) {
      const pairKey = pairSignature(node.parent_key, node.name);
      const candidates = removedByPair.get(pairKey);
      if (candidates && candidates.length > 0) {
        const removedKey = candidates.shift();
        pairs.push([removedKey, addedKey]);
        removedToPair.add(removedKey);
        addedToPair.add(addedKey);
      }
    }

    return { pairs, removedToPair, addedToPair };
  },

  applyRestartPair(removedKey, addedKey, addedNode) {
    // Add the new node already (invisible), then fade out the old, then remove old + fade in new.
    const newEls = elementsFor(addedKey, addedNode);
    this.cy.add(newEls);
    const newNode = this.cy.getElementById(addedKey);
    newNode.addClass('entering');

    const oldNode = this.cy.getElementById(removedKey);
    if (oldNode.nonempty()) oldNode.addClass('leaving');

    if (this.fadeTimers.has(removedKey)) {
      clearTimeout(this.fadeTimers.get(removedKey));
    }

    const t = setTimeout(() => {
      this.fadeTimers.delete(removedKey);
      this.cy.batch(() => {
        const o = this.cy.getElementById(removedKey);
        if (o.nonempty()) {
          o.connectedEdges().remove();
          o.remove();
          this.tearDownOverlay(removedKey);
        }
        newNode.removeClass('entering');
      });
    }, FADE_MS);

    this.fadeTimers.set(removedKey, t);
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
    });

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

  // ---------------------------------------------------------------------------
  // Interactions
  // ---------------------------------------------------------------------------

  onNodeTap(e) {
    const key = e.target.id();
    const now = Date.now();

    // Detect double-tap directly: a second tap on the same key within the
    // guard window cancels the pending single-tap and fires toggle-expand.
    if (
      this.lastTapId === key &&
      now - this.lastTapTs < DBLTAP_GUARD_MS &&
      this.pendingSelectTimer
    ) {
      clearTimeout(this.pendingSelectTimer);
      this.pendingSelectTimer = null;
      this.lastTapId = null;
      this.lastTapTs = 0;
      if (isRealPid(key)) {
        this.pushEventTo(this.el, 'toggle-expand', { pid: key });
      }
      if (this.isCollapsed(e.target)) {
        e.target.successors().removeClass('hidden');
        e.target.data('is_collapsed', false);
      } else {
        e.target.successors().addClass('hidden');
        e.target.data('is_collapsed', true);
      }
      this.scheduleLayout();
      return;
    }

    this.lastTapId = key;
    this.lastTapTs = now;
    if (this.pendingSelectTimer) clearTimeout(this.pendingSelectTimer);
    this.pendingSelectTimer = setTimeout(() => {
      this.pendingSelectTimer = null;
      this.pushEventTo(this.el, 'select-node', { key });
    }, DBLTAP_GUARD_MS + 10);
  },

  onBackgroundTap() {
    this.pushEventTo(this.el, 'select-node', { key: '' });
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

  // ---------------------------------------------------------------------------
  // Popper overlays
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
      ev.stopPropagation();
      if (isRealPid(key)) {
        this.pushEventTo(this.el, 'toggle-expand', { pid: key });
      }
      if (this.isCollapsed(node)) {
        node.successors().removeClass('hidden');
        node.data('is_collapsed', false);
      } else {
        node.successors().addClass('hidden');
        node.data('is_collapsed', true);
      }
      this.scheduleLayout();
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

  // ---------------------------------------------------------------------------
  // Theme tokens
  // ---------------------------------------------------------------------------

  readTokens() {
    const cs = getComputedStyle(this.el);
    return {
      base100: getColor(cs, '--color-base-100') || '#ffffff',
      base200: getColor(cs, '--color-base-200') || '#f5f5f5',
      base300: getColor(cs, '--color-base-300') || '#e5e5e5',
      base500: getColor(cs, '--color-base-500') || '#CAD5E2',
      baseContent: getColor(cs, '--color-base-content') || '#1a1a1a',
      primary: getColor(cs, '--color-primary') || '#3b82f6',
      primaryContent: getColor(cs, '--color-primary-content') || '#ffffff',
      error: getColor(cs, '--color-error') || '#ef4444',
    };
  },

  refreshTokens() {
    this.tokens = this.readTokens();
    this.cy.style(buildStyle(this.tokens));
  },
};

// ---------------------------------------------------------------------------
// Pure helpers
// ---------------------------------------------------------------------------

function buildStyle(t) {
  return [
    {
      selector: 'node',
      style: {
        shape: 'round-rectangle',
        width: 14,
        height: 14,
        'background-color': t.base100,
        'border-color': t.primary,
        'border-width': 2,
        label: 'data(displayLabel)',
        'text-halign': 'right',
        'text-valign': 'center',
        'text-margin-x': 6,
        'text-background-opacity': 1,
        'text-background-color': t.base100,
        'font-size': 11,
        'font-family': 'ui-monospace, SFMono-Regular, Menlo, monospace',
        color: t.baseContent,
        // 'text-opacity': 0.6,
        'overlay-padding': 8,
        'transition-property':
          'background-color, border-color, opacity, text-opacity',
        'transition-duration': '80ms',
        'transition-timing-function': 'ease-out',
      },
    },
    {
      selector: 'node.hover',
      style: {
        'background-color': t.primary,
      },
    },
    {
      selector: 'node[type = "worker"]',
      style: {
        shape: 'ellipse',
        width: 14,
        height: 14,
      },
    },
    {
      selector: 'node[type = "app"]',
      style: {
        shape: 'round-diamond',
        width: 14,
        height: 14,
        'border-width': 3,
        color: t.baseContent,
      },
    },
    {
      selector: 'node[?dead]',
      style: {
        opacity: 0.4,
        'border-color': t.error,
      },
    },
    {
      selector: 'node.in-path',
      style: {
        'background-color': t.primary,
        'border-color': t.primary,
        'text-opacity': 1,
        'font-weight': 600,
      },
    },
    {
      selector: 'node.leaving',
      style: { opacity: 0 },
    },
    {
      selector: 'node.entering',
      style: { opacity: 0 },
    },
    {
      selector: 'edge',
      style: {
        'curve-style': 'unbundled-bezier',

        'source-endpoint': 'outside-to-node-or-label',
        'target-endpoint': 'outside-to-node-or-label',

        // TENSION = how strongly the curve is pulled horizontally.
        // 0.5 = aggressive boxy S-curve
        // 0.25 to 0.35 = smooth, gentle sweep
        // 0.1 = almost a straight diagonal line
        'control-point-distances': function (edge) {
          const TENSION = 0.3;

          const source = edge.source().position();
          const target = edge.target().position();
          const dx = target.x - source.x;
          const dy = target.y - source.y;

          const length = Math.sqrt(dx * dx + dy * dy);
          if (length === 0) return [0, 0];

          const dist = (TENSION * (dx * dy)) / length;
          return [-dist, dist];
        },
        'control-point-weights': function (edge) {
          const TENSION = 0.3;

          const source = edge.source().position();
          const target = edge.target().position();
          const dx = target.x - source.x;
          const dy = target.y - source.y;

          const lengthSq = dx * dx + dy * dy;
          if (lengthSq === 0) return [0.5, 0.5];

          const w1 = (TENSION * dx * dx) / lengthSq;
          const w2 = ((1 - TENSION) * dx * dx + dy * dy) / lengthSq;

          return [w1, w2];
        },
        'line-color': t.base500,
        width: 1.4,
        'target-arrow-shape': 'none',
        'transition-property': 'line-color, width, opacity',
        'transition-duration': '80ms',
      },
    },
    {
      selector: 'edge.in-path',
      style: {
        'line-color': t.primary,
        width: 1.8,
        opacity: 1,
        'z-index': 10,
      },
    },
    {
      selector: 'edge.leaving',
      style: { opacity: 0 },
    },
    {
      selector: '.hidden',
      style: { display: 'none' },
    },
  ];
}

function elementsFor(key, node) {
  const has_children = !!node['has_children?'];
  const children_keys =
    node.children_keys === 'not_loaded' ? null : node.children_keys;

  const data = {
    id: key,
    name: node.name,
    type: node.type,
    info: node.info,
    has_children,
    child_count: node.child_count ?? 0,
    parent_key: node.parent_key,
    children_keys:
      node.children_keys === 'not_loaded' ? null : node.children_keys,
    dead: node.info === 'dead',
    is_collapsed: has_children && children_keys === null,
  };
  data.displayLabel = composeLabel(data);

  const els = [{ group: 'nodes', data }];

  if (node.parent_key) {
    els.push({
      group: 'edges',
      data: {
        id: edgeId(node.parent_key, key),
        source: node.parent_key,
        target: key,
      },
    });
  }

  return els;
}

function composeLabel(d) {
  const name = formatName(d.name);
  if (d.type === 'worker' || d.child_count === 0 || d.child_count == null) {
    return name;
  }
  return `${name} (${d.child_count})`;
}

function formatName(name) {
  if (name === null || name === undefined) return '';
  if (Array.isArray(name)) return name.map(formatName).join(':');
  if (typeof name === 'string') return name;
  return String(name);
}

function edgeId(parentKey, childKey) {
  return `e:${parentKey}->${childKey}`;
}

function pairSignature(parentKey, name) {
  return `${parentKey ?? ''}|${formatName(name)}`;
}

function isRealPid(key) {
  return typeof key === 'string' && key.startsWith('<') && key.endsWith('>');
}

function nodeIntersectsExtent(node, extent) {
  const bb = node.boundingBox();
  return !(
    bb.x2 < extent.x1 ||
    bb.x1 > extent.x2 ||
    bb.y2 < extent.y1 ||
    bb.y1 > extent.y2
  );
}

function toggleIcon(collapsed) {
  if (collapsed) {
    // plus
    return `<svg viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><line x1="6" y1="2.5" x2="6" y2="9.5"/><line x1="2.5" y1="6" x2="9.5" y2="6"/></svg>`;
  }
  // minus
  return `<svg viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><line x1="2.5" y1="6" x2="9.5" y2="6"/></svg>`;
}

function getColor(cs, value) {
  const color = cs.getPropertyValue(value).trim();
  if (color) {
    return new Color(color).to('srgb').toString({ format: 'hex' });
  }
  return color;
}

export default SupervisionTree;
