// Remembers a table's controls across visits.
//
// The server owns validation: this pushes the stored values up on mount and
// writes back whatever the server echoes after validating them, so nothing
// invalid can be persisted or restored.

const STORAGE_PREFIX = 'voyager:table-settings:';

const TableSettings = {
  mounted() {
    this.storageKey =
      STORAGE_PREFIX + (this.el.dataset.settingsKey || this.el.id);

    this.handleEvent('store-settings', ({ settings }) => this.store(settings));
    this.restore();
  },

  /** @param {Record<string, unknown>} settings */
  store(settings) {
    try {
      localStorage.setItem(this.storageKey, JSON.stringify(settings));
    } catch (_error) {
      // Remembering the controls is a convenience, not correctness.
    }
  },

  // Always pushed, even with nothing stored: the server holds its first fetch
  // until this arrives, so staying silent would leave the page empty.
  restore() {
    let settings;

    try {
      const raw = localStorage.getItem(this.storageKey);
      settings = raw ? JSON.parse(raw) : null;
    } catch (_error) {
      settings = null;
    }

    const valid = settings && typeof settings === 'object' ? settings : {};

    this.pushEvent('restore_settings', valid);
  },
};

export default TableSettings;
