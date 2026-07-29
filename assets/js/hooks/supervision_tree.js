import cytoscape from 'cytoscape';
import dagre from 'cytoscape-dagre';

import { buildStyle } from './supervision_tree/styles';
import { graphMethods } from './supervision_tree/graph';
import { overlayMethods } from './supervision_tree/overlays';
import { tooltipMethods } from './supervision_tree/tooltips';

cytoscape.use(dagre);

/** @type {any} */
const SupervisionTree = {
  mounted() {
    this.initGraph();
    this.initOverlay();
    this.initTooltip();

    this.tokens = this.readTokens();
    this.cy = cytoscape({
      container: this.el.querySelector('[data-cy-container]'),
      elements: [],
      style: buildStyle(this.tokens),
      wheelSensitivity: 0.2,
      minZoom: 0.1,
      maxZoom: 2.5,
      autoungrabify: true,
    });

    // Test handle: lets e2e tests inspect graph state via page.evaluate.
    this.el._cy = this.cy;
    this.disabledClick = false;

    this.cy.on('onetap', 'node', (event) => {
      if (this.disabledClick) return;
      this.applyEdgeHighlight(null);
      this.pushEventTo(this.el, 'select-node', { key: event.target.id() });
    });
    this.cy.on('tap', 'edge', (event) => {
      if (this.disabledClick) return;
      this.selectEdge(event.target);
    });
    this.cy.on('dbltap', 'node', (event) => {
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
        this.scheduleShowTooltip(event.target.id());
      }
    });
    this.cy.on('mouseout', 'node, edge', (event) => {
      event.target.removeClass('hover');
      event.cy.container().style.cursor = '';

      if (event.target.isNode()) {
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
    this.cleanupGraph();
    this.cleanupOverlay();
    this.cleanupTooltip();
    if (this.themeObserver) this.themeObserver.disconnect();
    if (this.cy) this.cy.destroy();
    this.el._cy = null;
  },

  // Behavior is split across focused mixins (see ./supervision_tree/*), all
  // sharing the same `this` hook instance:
  //   - graphMethods:   payload application, layout, selection, expand/collapse
  //   - overlayMethods: expand/collapse toggle buttons overlaid on the canvas
  //   - tooltipMethods: the node hover tooltip
  ...graphMethods,
  ...overlayMethods,
  ...tooltipMethods,
};

export default SupervisionTree;
