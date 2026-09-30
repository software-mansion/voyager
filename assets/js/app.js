// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import 'phoenix_html';
import { Socket } from 'phoenix';
import { LiveSocket } from 'phoenix_live_view';
import { hooks as colocatedHooks } from 'phoenix-colocated/voyager';
import topbar from '../vendor/topbar';
import SupervisionTree from './hooks/supervision_tree';
import Tooltip from './hooks/tooltip';
import NumberStepper from './hooks/number_stepper';
import DetailsPanelResize from './hooks/details_panel_resize';
import TableSettings from './hooks/table_settings';

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute('content');
const liveSocket = new LiveSocket('/live', Socket, {
  params: { _csrf_token: csrfToken },
  hooks: {
    SupervisionTree,
    Tooltip,
    NumberStepper,
    DetailsPanelResize,
    TableSettings,
    ...colocatedHooks,
  },
});

// Inside the Tauri webview, `target="_blank"` links do nothing because there is
// no browser to open a new tab. Intercept them and hand the URL to the Tauri
// opener plugin so they open in the user's default browser instead.
//
// We call the plugin command through `__TAURI_INTERNALS__.invoke`, which Tauri
// always injects into every webview, rather than `window.__TAURI__.opener`,
// which only exists when the opener guest JS bindings have been injected.
// See https://v2.tauri.app/reference/javascript/opener/
if (window.__TAURI_INTERNALS__) {
  document.addEventListener(
    'click',
    (e) => {
      if (
        e.defaultPrevented ||
        e.button !== 0 ||
        e.metaKey ||
        e.altKey ||
        e.ctrlKey ||
        e.shiftKey
      ) {
        return;
      }

      const target = e.target;
      if (!(target instanceof Element)) return;

      const link = target.closest('a[target="_blank"]');
      if (!link?.href) return;

      const url = new URL(link.href);
      if (!['http:', 'https:', 'mailto:', 'tel:'].includes(url.protocol)) {
        return;
      }

      e.preventDefault();
      window.__TAURI_INTERNALS__.invoke('plugin:opener|open_url', {
        url: url.href,
      });
    },
    true
  );

  document.addEventListener('wheel', (e) => {
    if (e.ctrlKey) e.stopPropagation();
  });
}

const isMac = navigator.platform.startsWith('Mac');
document.documentElement.classList.toggle('is-mac', isMac);

window.addEventListener('keydown', (e) => {
  if (e.repeat || e.code !== 'KeyB' || !(isMac ? e.metaKey : e.ctrlKey)) return;

  for (const toggle of document.querySelectorAll(
    '#sidebar-compact-toggle, #sidebar-compact-toggle-wide'
  )) {
    if (toggle instanceof HTMLElement && toggle.offsetParent) {
      e.preventDefault();
      toggle.click();
      return;
    }
  }
});

topbar.config({ barColors: { 0: '#29d' }, shadowColor: 'rgba(0, 0, 0, .3)' });
window.addEventListener('phx:page-loading-start', (_info) => topbar.show(300));
window.addEventListener('phx:page-loading-stop', (_info) => topbar.hide());

liveSocket.connect();
window.liveSocket = liveSocket;

if (process.env.NODE_ENV === 'development') {
  window.addEventListener(
    'phx:live_reload:attached',
    ({ detail: reloader }) => {
      reloader.enableServerLogs();

      let keyDown;
      window.addEventListener('keydown', (e) => (keyDown = e.key));
      window.addEventListener('keyup', (_e) => (keyDown = null));
      window.addEventListener(
        'click',
        (e) => {
          if (keyDown === 'c') {
            e.preventDefault();
            e.stopImmediatePropagation();
            reloader.openEditorAtCaller(e.target);
          } else if (keyDown === 'd') {
            e.preventDefault();
            e.stopImmediatePropagation();
            reloader.openEditorAtDef(e.target);
          }
        },
        true
      );

      window.liveReloader = reloader;
    }
  );
}
