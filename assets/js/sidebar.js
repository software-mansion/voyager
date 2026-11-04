// Sidebar width lives on <html data-sidebar>, applied before first paint by the root layout.
const STORAGE_KEY = 'voyager:sidebar';

export function isSidebarCompact() {
  const mode = document.documentElement.dataset.sidebar;
  if (mode) return mode === 'compact';
  return window.matchMedia('(max-width: 1023.98px)').matches;
}

export function toggleSidebar() {
  const mode = isSidebarCompact() ? 'full' : 'compact';
  document.documentElement.dataset.sidebar = mode;
  try {
    localStorage.setItem(STORAGE_KEY, mode);
  } catch (_error) {}
}
