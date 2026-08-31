// Remembers a table's settings (fetch size, timeout, columns, search, rows per
// page) across visits.
//
// The settings already live in the query string, which is the source of truth:
// this only mirrors it to localStorage, and restores it when the page is opened
// without any of those params. That keeps links shareable — an explicit URL
// always wins over what was stored.

const STORAGE_PREFIX = 'voyager:table-settings:';

/** Params owned by the table; anything else in the URL is left alone. */
const KEYS = ['limit', 'timeout', 'columns', 'search', 'page_size'];

const TableSettings = {
  mounted() {
    this.storageKey =
      STORAGE_PREFIX + (this.el.dataset.settingsKey || this.el.id);

    if (!this.restore()) this.save();
  },

  updated() {
    this.save();
  },

  /**
   * Writes the current values of the owned params.
   * @returns {void}
   */
  save() {
    const current = new URLSearchParams(window.location.search);
    const settings = {};

    KEYS.forEach((key) => {
      const value = current.get(key);
      if (value !== null) settings[key] = value;
    });

    try {
      localStorage.setItem(this.storageKey, JSON.stringify(settings));
    } catch (_error) {
      // Remembering settings is a convenience, not correctness.
    }
  },

  /**
   * Restores stored settings, but only when the URL names none of them —
   * otherwise a shared link would be silently rewritten.
   * @returns {boolean} whether a navigation was triggered
   */
  restore() {
    const current = new URLSearchParams(window.location.search);
    if (KEYS.some((key) => current.has(key))) return false;

    let settings;
    try {
      const raw = localStorage.getItem(this.storageKey);
      settings = raw ? JSON.parse(raw) : null;
    } catch (_error) {
      return false;
    }

    if (!settings || typeof settings !== 'object') return false;

    const entries = KEYS.filter((key) => typeof settings[key] === 'string');
    if (entries.length === 0) return false;

    entries.forEach((key) => current.set(key, settings[key]));

    // A full replace-navigation rather than a LiveView patch: patching relies
    // on a private API, and this runs once on mount where the extra round trip
    // costs nothing. `replace` keeps the settings-less URL out of history, so
    // Back still leaves the page instead of re-triggering a restore.
    window.location.replace(
      `${window.location.pathname}?${current.toString()}`
    );

    return true;
  },
};

export default TableSettings;
