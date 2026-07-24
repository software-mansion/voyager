import cytoscape from 'cytoscape';
import dagre from 'cytoscape-dagre';

import {
  TOOLTIP_DELAY_MS,
  LAYOUT_DEBOUNCE_MS,
  OVERLAY_DEBOUNCE_MS,
  OVERLAY_MIN_ZOOM,
  TOPOLOGY_FIELDS,
  TOOLTIP_GAP,
  VIEWPORT_MARGIN,
} from './supervision_tree/constants';
import { buildStyle, toggleIcon, getColor } from './supervision_tree/styles';
import {
  elementsFor,
  relEdgeElement,
  composeLabel,
  formatName,
  edgeId,
  isRealPid,
  overlayButtonIntersectsExtent,
  initialIsCollapsedState,
} from './supervision_tree/elements';

/**
 * @import {ServerNode, ServerEdge, Info} from './supervision_tree/elements.js'
 */

cytoscape.use(dagre);

const SupervisionTree = {
  mounted() {
    this._closeTimeout;
    this._openTimeout;

    this.container = this.el.querySelector('[data-cy-container]');
    this.overlayLayer = this.el.querySelector('[data-cy-overlays]');
    this.tooltip = document.querySelector('#supervision-tree-node-snippet-tip');

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

    // Test handle: lets e2e tests inspect graph state via page.evaluate.
    this.el._cy = this.cy;

    this.layoutTimer = null;
    this.overlayTimer = null;
    this.overlays = new Map();
    this.fadeTimers = new Map();
    this.disabledClick = false;
    this.selectedEdgeId = null;
    this.selectedPath = null;
    this.hoveredNodeId = null;

    this.cy.on('oneclick', 'node', (event) => {
      if (this.disabledClick) return;
      this.applyEdgeHighlight(null);
      this.pushEventTo(this.el, 'select-node', { key: event.target.id() });
    });
    this.cy.on('tap', 'edge', (event) => {
      if (this.disabledClick) return;
      this.selectEdge(event.target);
    });
    this.cy.on('dblclick', 'node', (event) => {
      if (this.disabledClick) return;
      this.toggleExpandNode(event.target);
    });
    this.cy.on('tap', (event) => {
      if (this.disabledClick) return;
      if (event.target === this.cy) {
        this.applyEdgeHighlight(null);
        this.pushEventTo(this.el, 'select-node', { key: '' });
      }
    });

    this.cy.on('mouseover', 'node, edge', (event) => {
      event.target.addClass('hover');
      event.cy.container().style.cursor = 'pointer';

      if (event.target.isNode()) {
        this.hoveredNodeId = event.target.id();
        this.scheduleShowTooltip();
      }
    });
    this.cy.on('mouseout', 'node, edge', (event) => {
      event.target.removeClass('hover');
      event.cy.container().style.cursor = '';

      if (event.target.isNode()) {
        this.hoveredNodeId = null;
        this.scheduleCloseTooltip();
      }
    });

    this.cy.on('viewport', () => {
      this.repositionOverlays();
      this.scheduleOverlayReconcile();
    });
    this.cy.on('render', () => {
      this.repositionOverlays();
      this.reconcileTooltip();
    });

    this.handleEvent('tree-data', (p) => this.applyPayload(p));
    this.handleEvent('path-highlight', (p) => this.applyPathHighlight(p));
    this.el.addEventListener('zoom-in', () => this.zoomBy(1.2));
    this.el.addEventListener('zoom-out', () => this.zoomBy(0.8));
    this.el.addEventListener('maximize', () =>
      this.scheduleLayout({ fit: true })
    );

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
    this.el._cy = null;
  },

  // ---------------------------------------------------------------------------
  // Payload application
  // ---------------------------------------------------------------------------

  /**
   * @typedef {Object} FullPayload
   * @property {'full'} kind
   * @property {'initial'|'auto_refresh'|'manual_refresh'|'toggle_expand'} request_type
   * @property {Record<string, ServerNode>} nodes
   * @property {Record<string, ServerEdge>} edges
   *
   * @typedef {Object} Patch
   * @property {string} name
   * @property {'app'|'supervisor'|'worker'|'port'|'reference'} type
   * @property {number} child_count
   * @property {Info|'dead'|null} info
   * @property {string[]|'not_loaded'} children_keys
   *
   * @typedef {Object} DeltaPayload
   * @property {'delta'} kind
   * @property {'initial'|'auto_refresh'|'manual_refresh'|'toggle_expand'} request_type
   * @property {Record<string, ServerNode>} added
   * @property {string[]} removed
   * @property {Record<string, Patch>} updated
   * @property {Record<string, ServerEdge>} edges_added
   * @property {string[]} edges_removed
   *
   * @param {FullPayload|DeltaPayload} payload
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

            if (value) {
              this.cy.add({
                group: 'edges',
                data: { id: edgeId(value, key), source: value, target: key },
              });
            }
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
      for (const edge of Object.values(edgesAdded)) {
        if (this.cy.getElementById(edge.id).nonempty()) continue;
        const source = this.cy.getElementById(edge.source);
        const target = this.cy.getElementById(edge.target);
        if (source.nonempty() && target.nonempty()) {
          this.cy.add(relEdgeElement(edge));
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
      animate: true,
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
    if (this.layoutTimer) clearTimeout(this.layoutTimer);
    this.layoutTimer = setTimeout(() => {
      this.layoutTimer = null;
      this.runLayout({ fit });
      this.scheduleOverlayReconcile();
    }, LAYOUT_DEBOUNCE_MS);
  },

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
      this.cy.nodes('[child_count > 0]').forEach((node) => {
        if (overlayButtonIntersectsExtent(node, extent, this.cy.zoom())) {
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
    this.decorateOverlay(dom, node);
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

    // Keep icon and attributes in sync with the node's state.
    const collapsed = this.isCollapsed(node);
    const name = formatName(node.data('name'));
    if (entry.collapsed !== collapsed || entry.name !== name) {
      this.decorateOverlay(entry.dom, node);
      entry.collapsed = collapsed;
      entry.name = name;
    }
  },

  // Sets the icon plus the a11y/testability attributes from the node's state.
  decorateOverlay(dom, node) {
    const collapsed = this.isCollapsed(node);
    const name = formatName(node.data('name'));
    dom.innerHTML = toggleIcon(collapsed);
    dom.dataset.name = name;
    dom.dataset.collapsed = String(collapsed);
    dom.setAttribute(
      'aria-label',
      `${collapsed ? 'Expand' : 'Collapse'} ${name}`
    );
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

  scheduleShowTooltip() {
    clearTimeout(this._closeTimeout);
    clearTimeout(this._openTimeout);

    this._togglingTooltip = true;

    this._openTimeout = setTimeout(() => {
      this.fillTooltip();
      setTimeout(() => {
        this.positionTooltip();
        this._togglingTooltip = false;
      });
    }, TOOLTIP_DELAY_MS);
  },

  scheduleCloseTooltip() {
    clearTimeout(this._closeTimeout);
    clearTimeout(this._openTimeout);

    this._togglingTooltip = true;

    this._closeTimeout = setTimeout(() => {
      this.toggleTooltipOpen(false);
      this._togglingTooltip = false;
    }, TOOLTIP_DELAY_MS);
  },

  reconcileTooltip() {
    clearTimeout(this._tooltipReconcileTimeout);
    if (this._togglingTooltip) return;
    this._tooltipReconcileTimeout = setTimeout(() => {
      this.positionTooltip();
    }, TOOLTIP_DELAY_MS);
  },

  toggleTooltipOpen(isOpen) {
    this.tooltip.classList.toggle('is-open', isOpen);
  },

  fillTooltip() {
    if (!this.hoveredNodeId) return;

    const node = this.cy.getElementById(this.hoveredNodeId);
    if (
      node.empty() ||
      node.hasClass('hidden') ||
      this.cy.zoom() < OVERLAY_MIN_ZOOM
    )
      return;

    /**
     * @param {string} type
     */
    function typeColorClass(type) {
      switch (type) {
        case 'app':
          return 'text-primary';
        case 'supervisor':
          return 'text-primary';
        case 'worker':
          return 'text-secondary';
        case 'port':
          return 'text-port';
        case 'reference':
          return 'text-success';
        default:
          return '';
      }
    }

    /**
     * @param {[string, string, number] | undefined} mfa
     * @param {string} [label]
     */
    function parseMfa(mfa, label = '') {
      if (!Array.isArray(mfa) || mfa.length !== 3) return '';
      const [m, f, a] = mfa;
      return `<li>${label} <span class="text-primary">${m}.${f}/${a}</span></li>`;
    }

    const { name, type, pid, info, app } = node.data();

    const displayName = formatName(info?.registered_name) || formatName(name);

    this.tooltip.innerHTML = `
          <ul class="flex font-mono flex-col gap-1 break-all">
            <li class="${typeColorClass(type)}">${type}</li>
            <li class="font-semibold my-1">${displayName}</li>
            ${app ? `<li>app: <span class="font-semibold">${app}</span></li>` : ''}
            ${parseMfa(info?.initial_call, 'initial_call:')}
            ${parseMfa(info?.current_function, 'current_function:')}
            ${pid ? `<li>PID: <span class="font-semibold">${pid}</span></li>` : ''}
          </ul>
        `;
  },

  positionTooltip() {
    if (!this.hoveredNodeId) return;

    const node = this.cy.getElementById(this.hoveredNodeId);

    if (
      node.empty() ||
      node.hasClass('hidden') ||
      this.cy.zoom() < OVERLAY_MIN_ZOOM
    ) {
      this.toggleTooltipOpen(false);
      return;
    }

    const { x: nodeCenterX } = node.renderedPosition();
    const { y1: nodeY } = node.renderedBoundingBox({
      includeLabels: false,
    });

    const tipRect = this.tooltip.getBoundingClientRect();
    const containerRect = this.container.getBoundingClientRect();

    let top = containerRect.y + nodeY - tipRect.height - TOOLTIP_GAP;
    let left = containerRect.x + nodeCenterX - tipRect.width / 2;

    left = Math.max(
      VIEWPORT_MARGIN,
      Math.min(left, window.innerWidth - tipRect.width - VIEWPORT_MARGIN)
    );
    top = Math.max(
      VIEWPORT_MARGIN,
      Math.min(top, window.innerHeight - tipRect.height - VIEWPORT_MARGIN)
    );

    this.tooltip.style.top = `${top}px`;
    this.tooltip.style.left = `${left}px`;

    this.toggleTooltipOpen(true);
  },

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
      ele.data('hidden_count', Math.max(current + delta, 0));
    };

    this.cy.batch(() => {
      if (this.isCollapsed(node)) {
        // Expand: decrement the hidden_count of every successor, then reveal
        // those no longer hidden by any other collapsed ancestor.
        node.data('is_collapsed', false);
        node.successors().forEach((ele) => bumpHiddenCount(ele, -1));
        node.successors('[hidden_count = 0]').removeClass('hidden');
      } else {
        // Collapse: hide tree successors outright.
        node.data('is_collapsed', true);

        const treeSuccessors = node.successors('[!is_from_relation]');

        treeSuccessors
          .filter((ele) => {
            const incomers = ele.incomers('node');
            return treeSuccessors.contains(incomers) || incomers.contains(node);
          })
          .forEach((ele) => {
            bumpHiddenCount(ele, 1);
            ele.addClass('hidden');
          });

        // Hide relation successors only once all of their edges are hidden.
        node.successors('[?is_from_relation]').forEach((ele) => {
          const connectedEdges = this.cy
            .elements('edge[target="' + ele.id() + '"]')
            .union(this.cy.elements('edge[source="' + ele.id() + '"]'));

          const visibleEdges =
            connectedEdges.length - connectedEdges.edges('.hidden').length;

          if (visibleEdges == 0) {
            bumpHiddenCount(ele, 1);
            ele.addClass('hidden');
          }
        });
      }
    });

    this.scheduleLayout();
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

export default SupervisionTree;
