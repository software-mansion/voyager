import { TOOLTIP_DELAY_MS, OVERLAY_MIN_ZOOM, TOOLTIP_GAP } from './constants';
import { formatName, formatPid } from './elements';
import { placeTooltip } from '../tooltip';

const TYPE_COLOR_CLASS = {
  app: 'text-primary',
  supervisor: 'text-primary',
  worker: 'text-secondary',
  port: 'text-port',
  reference: 'text-success',
};

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
    this.togglingTooltip = false;
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

    const pidNodeId = this.el.dataset.nodeId;
    const displayName =
      formatName(info?.registered_name, pidNodeId) ||
      formatName(name, pidNodeId);

    this.tooltip.innerHTML = `
          <ul class="flex font-mono flex-col gap-1 break-all">
            <li class="${TYPE_COLOR_CLASS[type] ?? ''}">${escapeHtml(type)}</li>
            <li class="font-semibold my-1">${escapeHtml(displayName)}</li>
            ${app ? `<li>app: <span class="font-semibold">${escapeHtml(app)}</span></li>` : ''}
            ${parseMfa(info?.initial_call, 'initial_call:')}
            ${parseMfa(info?.current_function, 'current_function:')}
            ${pid ? `<li>PID: <span class="font-semibold">${escapeHtml(formatPid(pid, pidNodeId))}</span></li>` : ''}
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

    placeTooltip(this.tooltip, (tipRect) => {
      const containerRect = this.cy.container().getBoundingClientRect();
      return {
        top: containerRect.y + nodeY - tipRect.height - TOOLTIP_GAP,
        left: containerRect.x + nodeCenterX - tipRect.width / 2,
      };
    });

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
 * @param {[string, string, number] | undefined} mfa
 * @param {string} [label]
 */
function parseMfa(mfa, label = '') {
  if (!Array.isArray(mfa) || mfa.length !== 3) return '';
  const [m, f, a] = mfa;
  return `<li>${escapeHtml(label)} <span class="text-primary">${escapeHtml(m)}.${escapeHtml(f)}/${escapeHtml(a)}</span></li>`;
}
