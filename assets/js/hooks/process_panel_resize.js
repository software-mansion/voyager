// Resizes the ProcessPanel by dragging its left edge.
// Width is --process-panel-width on #process-panel (px). CSS clamps via
// min-width / max-width: 100%. Kept on `this.width` so LiveView morphs
// can restore it in `updated()` without snapping to the CSS default.

const STORAGE_KEY = 'voyager:process-panel-width';
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

const ProcessPanelResize = {
  mounted() {
    this.handle = this.el.querySelector('#process-panel-resize-handle');
    this.width =  getStoredWidth();
    this.apply();

    this.onPointerDown = (e) => this.begin(e);
    this.handle.addEventListener('pointerdown', this.onPointerDown);
  },

  updated() {
    if (!this.dragging) this.apply();
  },

  destroyed() {
    this.handle?.removeEventListener('pointerdown', this.onPointerDown);
    this.teardown();
  },

  apply() {
    this.el.style.setProperty('--process-panel-width', `${this.width}px`);
  },

  begin(event) {
    if (event.button !== 0) return;

    event.preventDefault();
    this.dragging = true;
    this.el.classList.add('select-none');
    document.body.style.cursor = 'col-resize';
    this.handle.setPointerCapture(event.pointerId);

    const startX = event.clientX;
    const startWidth = this.el.getBoundingClientRect().width;

    this.onMove = (e) => {
      this.width = startWidth + (startX - e.clientX);
      this.apply();
    };

    this.onUp = (e) => {
      if (this.handle.hasPointerCapture(e.pointerId)) {
        this.handle.releasePointerCapture(e.pointerId);
      }
      this.width = Number.parseFloat(getComputedStyle(this.el).width);
      setStoredWidth(this.width);
      this.teardown();
    };

    this.handle.addEventListener('pointermove', this.onMove);
    this.handle.addEventListener('pointerup', this.onUp);
    this.handle.addEventListener('pointercancel', this.onUp);
  },

  teardown() {
    this.dragging = false;
    this.el.classList.remove('select-none');
    document.body.style.cursor = '';
    if (this.onMove) {
      this.handle?.removeEventListener('pointermove', this.onMove);
      this.onMove = null;
    }
    if (this.onUp) {
      this.handle?.removeEventListener('pointerup', this.onUp);
      this.handle?.removeEventListener('pointercancel', this.onUp);
      this.onUp = null;
    }
  },
};

export default ProcessPanelResize;
