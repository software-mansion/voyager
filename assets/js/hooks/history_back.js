// Node header back button: shown when an in-app page is behind, except on entries reached via the sidebar.

const SIDEBAR_NAV_KEY = 'voyager:sidebar-nav';

document.addEventListener(
  'click',
  (e) => {
    if (!(e.target instanceof Element)) return;

    const link = e.target.closest('a[data-sidebar-nav]');
    const plainClick =
      e.button === 0 && !(e.metaKey || e.ctrlKey || e.shiftKey || e.altKey);

    if (link instanceof HTMLAnchorElement && plainClick) {
      sessionStorage.setItem(SIDEBAR_NAV_KEY, link.href);
    }
  },
  true
);

window.addEventListener('phx:navigate', () => {
  const href = sessionStorage.getItem(SIDEBAR_NAV_KEY);
  sessionStorage.removeItem(SIDEBAR_NAV_KEY);

  if (href === location.href) {
    history.replaceState({ ...history.state, sidebarNav: true }, '');
  }
});

// shortcut: reads LiveView's internal history.state.position (href reloads reset it, hence the referrer); recheck on LV upgrades.
function canGoBack() {
  return (
    !sessionStorage.getItem(SIDEBAR_NAV_KEY) &&
    !history.state?.sidebarNav &&
    (history.state?.position > 0 ||
      document.referrer.startsWith(location.origin))
  );
}

const HistoryBack = {
  mounted() {
    // LiveView pushes the new history entry after mount, so resync on phx:navigate.
    this.sync = () => {
      this.el.hidden = !canGoBack();
    };
    this.sync();
    window.addEventListener('phx:navigate', this.sync);
    this.el.addEventListener('click', () => history.back());
  },

  destroyed() {
    window.removeEventListener('phx:navigate', this.sync);
  },
};

export default HistoryBack;
