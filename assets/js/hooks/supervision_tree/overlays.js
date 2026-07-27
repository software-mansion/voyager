import { OVERLAY_DEBOUNCE_MS, OVERLAY_MIN_ZOOM } from './constants';
import { formatName, overlayButtonIntersectsExtent } from './elements';
import { toggleIcon } from './styles';

/**
 * Expand/collapse toggle buttons rendered as DOM overlays on top of the canvas.
 *
 * Mixed onto the SupervisionTree hook, so `this` is the hook instance and
 * shares `this.cy`, `this.overlays`, `this.overlayLayer`, etc. with the graph
 * mixin (e.g. `this.isCollapsed`, `this.toggleExpandNode`).
 */
export const overlayMethods = {
  /** @type {ReturnType<typeof setTimeout> | undefined} */ overlayTimer:
    undefined,
  overlays: new Map(),

  initOverlay() {
    this.overlayLayer = this.el.querySelector('[data-cy-overlays]');
  },

  scheduleOverlayReconcile() {
    clearTimeout(this.overlayTimer);
    this.overlayTimer = setTimeout(() => {
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
};
