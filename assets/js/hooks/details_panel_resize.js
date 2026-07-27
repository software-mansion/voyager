// Resizes the DetailsPanel by dragging its left edge.
// Width is --details-panel-width on #details-panel (px). CSS clamps via
// min-width / max-width: 100%. Kept on `this.width` so LiveView morphs
// can restore it in `updated()` without snapping to the CSS default.

const STORAGE_KEY = 'voyager:details-panel-width';
const DEFAULT_WIDTH = 320;

/**
 * @returns {number}
 */
function getStoredWidth() {
  const raw = localStorage.getItem(STORAGE_KEY);
  if (!raw) return DEFAULT_WIDTH;
  const width = Number.parseFloat(raw);
  return Number.isFinite(width) ? width : DEFAULT_WIDTH;
}

/**
 * @param {number} width
 */
function setStoredWidth(width) {
  localStorage.setItem(STORAGE_KEY, String(width));
}

const DetailsPanelResize = {
  mounted() {
    this.handle = this.el.querySelector('#details-panel-resize-handle');
    this.width = getStoredWidth();
    this.apply();

    this.onPointerDown = (e) => this.begin(e);
    this.handle.addEventListener('pointerdown', this.onPointerDown);
  },

  updated() {
    const handle = this.el.querySelector('#details-panel-resize-handle');
    if (handle && handle !== this.handle) {
      this.handle?.removeEventListener('pointerdown', this.onPointerDown);
      this.handle = handle;
      this.handle.addEventListener('pointerdown', this.onPointerDown);
    }
    if (!this.dragging) this.apply();
  },

  destroyed() {
    this.handle?.removeEventListener('pointerdown', this.onPointerDown);
    this.teardown();
  },

  apply() {
    this.el.style.setProperty('--details-panel-width', `${this.width}px`);
  },

  begin(event) {
    if (event.button !== 0) return;

    event.preventDefault();
    this.dragging = true;
    this.el.classList.add('select-none');
    document.body.style.cursor = 'col-resize';

    const startX = event.clientX;
    const startWidth = this.el.getBoundingClientRect().width;

    this.onMove = (e) => {
      this.width = startWidth + (startX - e.clientX);
      this.apply();
    };

    this.onUp = () => {
      const width = Number.parseFloat(getComputedStyle(this.el).width);
      if (Number.isFinite(width) && width > 0) this.width = width;
      setStoredWidth(this.width);
      this.teardown();
    };

    // Document-level listeners so the drag keeps working if the pointer
    // leaves the thin handle (and so Playwright mouse moves are reliable).
    document.addEventListener('pointermove', this.onMove);
    document.addEventListener('pointerup', this.onUp);
    document.addEventListener('pointercancel', this.onUp);
  },

  teardown() {
    this.dragging = false;
    this.el.classList.remove('select-none');
    document.body.style.cursor = '';
    if (this.onMove) {
      document.removeEventListener('pointermove', this.onMove);
      this.onMove = null;
    }
    if (this.onUp) {
      document.removeEventListener('pointerup', this.onUp);
      document.removeEventListener('pointercancel', this.onUp);
      this.onUp = null;
    }
  },
};

export default DetailsPanelResize;
