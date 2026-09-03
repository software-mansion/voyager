// Remembers a table's controls across visits.
//
// Saves data on `store-settings`
// Sends `restore_settings` event on mount, empty when nothing is stored: the
// server holds its first fetch until it arrives, so a visit costs one scan
// rather than one with the defaults and another with the restored controls.

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

    this.pushEvent(
      'restore_settings',
      settings && typeof settings === 'object' ? settings : {}
    );
  },
};

export default TableSettings;
