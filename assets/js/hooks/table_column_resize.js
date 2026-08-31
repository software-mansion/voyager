// Resizes table columns by dragging a handle in the header.
//
// Resizing is zero-sum: a column takes width from (or gives it back to) its
// right-hand neighbour, so the table's total width never changes and it never
// starts scrolling sideways. Widths are stored as percentages, keyed by column
// and persisted per table id, so a layout survives reloads, morphs and window
// resizes.

const STORAGE_PREFIX = 'voyager:table-columns:';
const MIN_PERCENT = 4;
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

  /** @returns {HTMLElement[]} the header cells, in visual order */
  headers() {
    return Array.from(this.el.querySelectorAll('thead th[data-column]'));
  },

  /**
   * Applies stored widths, but only for the columns currently rendered — a
   * stored layout may name columns the user has since hidden.
   */
  apply() {
    const headers = this.headers();
    if (headers.length === 0) return;

    const keys = headers.map((th) => th.dataset.column);
    const stored = keys.filter((key) => typeof this.widths[key] === 'number');

    // Nothing stored for this column set: leave the CSS defaults alone.
    if (stored.length !== keys.length) return;

    const total = stored.reduce((sum, key) => sum + this.widths[key], 0);
    if (total <= 0) return;

    // Normalise to 100% so rounding drift cannot accumulate into an overflow.
    keys.forEach((key) => this.setWidth(key, (this.widths[key] / total) * 100));
  },

  /**
   * @param {string} key
   * @param {number} percent
   */
  setWidth(key, percent) {
    const width = `${percent.toFixed(4)}%`;

    this.el
      .querySelectorAll(`th[data-column="${key}"], td[data-column="${key}"]`)
      .forEach((/** @type {HTMLElement} */ cell) => {
        // Under fixed layout the header width governs, but the max-width also
        // has to move or the truncation box keeps the old size.
        cell.style.width = width;
        cell.style.maxWidth = width;
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

    const headers = this.headers();
    const index = headers.indexOf(header);
    const neighbour = headers[index + 1];

    // The last column has no neighbour to trade with, so it cannot be resized.
    if (!neighbour) return;

    event.preventDefault();
    event.stopPropagation();

    const tableWidth = this.el.getBoundingClientRect().width;
    if (tableWidth <= 0) return;

    const key = header.dataset.column;
    const neighbourKey = neighbour.dataset.column;
    const startX = event.clientX;

    // Percentages of the table, so the pair's sum is invariant.
    const startPercent =
      (header.getBoundingClientRect().width / tableWidth) * 100;
    const startNeighbourPercent =
      (neighbour.getBoundingClientRect().width / tableWidth) * 100;
    const pairTotal = startPercent + startNeighbourPercent;

    this.dragging = true;
    this.el.classList.add('select-none');
    document.body.style.cursor = 'col-resize';

    /** @param {PointerEvent} e */
    this.onMove = (e) => {
      const deltaPercent = ((e.clientX - startX) / tableWidth) * 100;

      // Clamp so neither side of the pair collapses; what one gains the other
      // loses, which is what keeps the table from overflowing.
      const width = Math.min(
        Math.max(startPercent + deltaPercent, MIN_PERCENT),
        pairTotal - MIN_PERCENT
      );

      this.widths[key] = width;
      this.widths[neighbourKey] = pairTotal - width;

      this.setWidth(key, width);
      this.setWidth(neighbourKey, pairTotal - width);
    };

    this.onUp = () => {
      // Persist every rendered column, not just the dragged pair, so the
      // layout can be restored as a whole.
      this.headers().forEach((th) => {
        const columnKey = th.dataset.column;
        if (typeof this.widths[columnKey] !== 'number') {
          this.widths[columnKey] =
            (th.getBoundingClientRect().width / tableWidth) * 100;
        }
      });

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
