// Resizes table columns by dragging a handle in the header.
//
// Widths are written as inline styles on the <th> and its matching <td>s (the
// table is fixed-layout, so the header width governs the column) and persisted
// per table id, keyed by column, so a layout survives reloads and LiveView
// morphs. Only columns whose header carries [data-resize-handle] participate.

const STORAGE_PREFIX = 'voyager:table-columns:';
const MIN_WIDTH = 60;
const HANDLE = '[data-resize-handle]';

/**
 * @param {string} tableId
 * @returns {Record<string, number>}
 */
function getStoredWidths(tableId) {
  try {
    const raw = localStorage.getItem(STORAGE_PREFIX + tableId);
    const parsed = raw ? JSON.parse(raw) : null;
    return parsed && typeof parsed === 'object' ? parsed : {};
  } catch (_error) {
    // A corrupt or unavailable store must not break the table.
    return {};
  }
}

/**
 * @param {string} tableId
 * @param {Record<string, number>} widths
 */
function setStoredWidths(tableId, widths) {
  try {
    localStorage.setItem(STORAGE_PREFIX + tableId, JSON.stringify(widths));
  } catch (_error) {
    // Ignore: a persisted width is a convenience, not correctness.
  }
}

const TableColumnResize = {
  mounted() {
    this.widths = getStoredWidths(this.el.id);
    /** @param {PointerEvent} e */
    this.onPointerDown = (e) => this.begin(e);
    this.bindHandles();
    this.apply();
  },

  updated() {
    // Re-bind after a morph: columns can be added or removed at runtime.
    this.bindHandles();
    if (!this.dragging) this.apply();
  },

  destroyed() {
    this.unbindHandles();
    this.teardown();
  },

  bindHandles() {
    this.unbindHandles();
    this.handles = Array.from(this.el.querySelectorAll(HANDLE));
    this.handles.forEach((/** @type {Element} */ h) =>
      h.addEventListener('pointerdown', this.onPointerDown)
    );
  },

  unbindHandles() {
    (this.handles || []).forEach((/** @type {Element} */ h) =>
      h.removeEventListener('pointerdown', this.onPointerDown)
    );
    this.handles = [];
  },

  /** Applies every stored width to its header and body cells. */
  apply() {
    Object.entries(this.widths).forEach(([key, width]) =>
      this.setWidth(key, width)
    );
  },

  /**
   * @param {string} key
   * @param {number} width
   */
  setWidth(key, width) {
    const px = `${Math.round(width)}px`;
    const header = /** @type {HTMLElement | null} */ (
      this.el.querySelector(`th[data-column="${key}"]`)
    );
    if (!header) return;

    // Both are needed: max-width alone loses to the table's own sizing, and
    // width alone is only a minimum under auto layout.
    header.style.width = px;
    header.style.maxWidth = px;

    this.el
      .querySelectorAll(`td[data-column="${key}"]`)
      .forEach((/** @type {HTMLElement} */ cell) => {
        cell.style.width = px;
        cell.style.maxWidth = px;
      });
  },

  /** @param {PointerEvent} event */
  begin(event) {
    if (event.button !== 0) return;

    const target = /** @type {Element} */ (event.target);
    const header = /** @type {HTMLElement | null} */ (
      target.closest('th[data-column]')
    );
    if (!header) return;

    event.preventDefault();
    event.stopPropagation();

    const key = header.dataset.column;
    const startX = event.clientX;
    const startWidth = header.getBoundingClientRect().width;

    this.dragging = true;
    this.el.classList.add('select-none');
    document.body.style.cursor = 'col-resize';

    /** @param {PointerEvent} e */
    this.onMove = (e) => {
      const width = Math.max(MIN_WIDTH, startWidth + (e.clientX - startX));
      this.widths[key] = width;
      this.setWidth(key, width);
    };

    this.onUp = () => {
      setStoredWidths(this.el.id, this.widths);
      this.teardown();
    };

    // Document-level so the drag continues when the pointer leaves the handle.
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

export default TableColumnResize;
