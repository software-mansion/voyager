// Per-tab UI settings set by `VoyagerWeb.Utils.SessionStorage`, sent on every LiveView join.

const PREFIX = 'voyager:';

/** @returns {{session_storage: Record<string, string>}} */
export function sessionStorageParams() {
  const values = {};

  try {
    for (let i = 0; i < sessionStorage.length; i++) {
      const key = sessionStorage.key(i);
      if (key?.startsWith(PREFIX)) {
        values[key.slice(PREFIX.length)] = sessionStorage.getItem(key);
      }
    }
  } catch (error) {
    console.warn(`Error while reading session storage: ${error}`);
  }

  return { session_storage: values };
}

window.addEventListener('voyager:session-storage:put', ({ detail }) => {
  try {
    sessionStorage.setItem(PREFIX + detail.key, detail.value);
  } catch (error) {
    console.warn(
      `Error while saving ${detail.key} to session storage: ${error}`
    );
  }
});
