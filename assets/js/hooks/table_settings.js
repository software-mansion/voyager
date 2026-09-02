// Remembers a table's controls across visits.
//
// Saves data on `store-settings`
// Sends `restore_settings` event when settings are restored.

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
    } catch (error) {
      console.warn(
        `Error while saving settings for table ${this.storageKey}: ${error}`
      );
    }
  },

  restore() {
    let settings;

    try {
      const raw = localStorage.getItem(this.storageKey);
      settings = raw ? JSON.parse(raw) : null;
    } catch (error) {
      console.warn(
        `Error while parsing saved setting for table ${this.storageKey}: ${error}`
      );
    }

    if (!settings || typeof settings !== 'object') return;

    this.pushEvent('restore_settings', settings);
  },
};

export default TableSettings;
