import {
  TOOLTIP_DELAY_MS,
  OVERLAY_MIN_ZOOM,
  TOOLTIP_GAP,
  VIEWPORT_MARGIN,
} from './constants';
import { formatName } from './elements';

/**
 * Hover tooltip showing the details of the node under the cursor.
 *
 * Mixed onto the SupervisionTree hook, so `this` is the hook instance and
 * shares `this.cy` with the rest of the hook.
 */
export const tooltipMethods = {
  /** @type {ReturnType<typeof setTimeout> | undefined} */
  closeTimer: undefined,
  /** @type {ReturnType<typeof setTimeout> | undefined} */
  openTimer: undefined,
  /** @type {ReturnType<typeof setTimeout> | undefined} */
  reconcileTimer: undefined,
  /** @type {ReturnType<typeof setTimeout> | undefined} */
  positionTimer: undefined,
  /** @type {boolean} */ togglingTooltip: false,
  /** @type {string | null} */ nodeId: null,

  initTooltip() {
    this.tooltip = document.querySelector('#supervision-tree-node-snippet-tip');
  },

  cleanupTooltip() {
    clearTimeout(this.openTimer);
    clearTimeout(this.closeTimer);
    clearTimeout(this.reconcileTimer);
    clearTimeout(this.positionTimer);
    this.nodeId = null;
    this.toggleTooltipOpen(false);
  },

  scheduleShowTooltip(nodeId) {
    this.nodeId = nodeId;

    clearTimeout(this.closeTimer);
    clearTimeout(this.openTimer);
    clearTimeout(this.positionTimer);

    this.togglingTooltip = true;

    this.openTimer = setTimeout(() => {
      this.fillTooltip();
      this.positionTimer = setTimeout(() => {
        this.positionTooltip();
        this.togglingTooltip = false;
      });
    }, TOOLTIP_DELAY_MS);
  },

  scheduleCloseTooltip() {
    this.nodeId = null;

    clearTimeout(this.closeTimer);
    clearTimeout(this.openTimer);
    clearTimeout(this.positionTimer);

    this.togglingTooltip = true;

    this.closeTimer = setTimeout(() => {
      this.toggleTooltipOpen(false);
      this.togglingTooltip = false;
    }, TOOLTIP_DELAY_MS);
  },

  reconcileTooltip() {
    clearTimeout(this.reconcileTimer);
    if (this.togglingTooltip) return;
    this.reconcileTimer = setTimeout(() => {
      this.positionTooltip();
    }, TOOLTIP_DELAY_MS);
  },

  toggleTooltipOpen(isOpen) {
    this.tooltip.classList.toggle('is-open', isOpen);
  },

  fillTooltip() {
    if (!this.nodeId) return;

    const node = this.cy.getElementById(this.nodeId);
    if (
      node.empty() ||
      node.hasClass('hidden') ||
      this.cy.zoom() < OVERLAY_MIN_ZOOM
    ) {
      this.toggleTooltipOpen(false);
      return;
    }

    const { name, type, pid, info, app } = node.data();

    const displayName = formatName(info?.registered_name) || formatName(name);

    this.tooltip.innerHTML = `
          <ul class="flex font-mono flex-col gap-1 break-all">
            <li class="${typeColorClass(type)}">${escapeHtml(type)}</li>
            <li class="font-semibold my-1">${escapeHtml(displayName)}</li>
            ${app ? `<li>app: <span class="font-semibold">${escapeHtml(app)}</span></li>` : ''}
            ${parseMfa(info?.initial_call, 'initial_call:')}
            ${parseMfa(info?.current_function, 'current_function:')}
            ${pid ? `<li>PID: <span class="font-semibold">${escapeHtml(pid)}</span></li>` : ''}
          </ul>
        `;
  },

  positionTooltip() {
    if (!this.nodeId) return;

    const node = this.cy.getElementById(this.nodeId);

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
    const containerRect = this.cy.container().getBoundingClientRect();

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
};

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

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
  return `<li>${escapeHtml(label)} <span class="text-primary">${escapeHtml(m)}.${escapeHtml(f)}/${escapeHtml(a)}</span></li>`;
}
