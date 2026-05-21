const BADGE_LABELS = { app: 'app', supervisor: 'sup', worker: 'wkr' };

const SupervisionTree = {
  mounted() {
    this.nodes = new Map();
    this.appKeys = [];
    this.collapsed = new Set();
    this.status = 'idle';
    this.errors = [];

    this.handleEvent('tree-data', (payload) => this.apply(payload));

    this.clickHandler = (e) => {
      const btn = e.target.closest('[data-toggle="expand"]');
      if (!btn || !this.el.contains(btn)) return;
      const key = btn.dataset.key;
      if (!key) return;

      if (this.collapsed.has(key)) {
        this.collapsed.delete(key);
      } else {
        this.collapsed.add(key);
      }
      this.render();

      if (isRealPid(key)) {
        this.pushEventTo(this.el, 'toggle-expand', { pid: key });
      }
    };
    this.el.addEventListener('click', this.clickHandler);

    this.render();
  },

  destroyed() {
    if (this.clickHandler) {
      this.el.removeEventListener('click', this.clickHandler);
    }
  },

  apply(payload) {
    console.log(payload);

    this.status = payload.status || 'idle';
    this.errors = payload.errors || [];

    if (payload.kind === 'full') {
      this.collapsed.clear();
      const nextNodes = new Map();
      const nextAppKeys = [];
      const incoming = payload.nodes || {};
      for (const [key, node] of Object.entries(incoming)) {
        const normalized = normalizeNode(node);
        nextNodes.set(key, normalized);
        if (normalized.children_keys === null) {
          this.collapsed.add(key);
        }
        if (
          normalized.parent_key === null ||
          normalized.parent_key === undefined
        ) {
          nextAppKeys.push(key);
        }
      }
      this.nodes = nextNodes;
      this.appKeys = nextAppKeys;

      // Drop expansions that no longer exist.
      // for (const key of [...this.collapsed]) {
      //   if (!this.nodes.has(key)) this.collapsed.delete(key);
      // }
    } else if (payload.kind === 'delta') {
      const removed = payload.removed || [];
      const added = payload.added || {};
      const updated = payload.updated || {};

      for (const key of removed) {
        this.nodes.delete(key);
        this.collapsed.delete(key);
      }

      for (const [key, node] of Object.entries(added)) {
        const normalized = normalizeNode(node);
        this.nodes.set(key, normalized);
        if (
          (normalized.parent_key === null ||
            normalized.parent_key === undefined) &&
          !this.appKeys.includes(key)
        ) {
          this.appKeys.push(key);
        }
      }

      for (const [key, patch] of Object.entries(updated)) {
        const existing = this.nodes.get(key);
        if (existing) {
          Object.assign(existing, normalizePatch(patch));
        }
      }

      if (removed.length > 0) {
        const removedSet = new Set(removed);
        this.appKeys = this.appKeys.filter((k) => !removedSet.has(k));
      }
    }

    this.render();
  },

  render() {
    if (this.nodes.size === 0 || this.appKeys.length === 0) {
      this.el.innerHTML = `
        <div class="text-base-content/50 flex h-24 items-center justify-center text-sm italic">
          Loading supervision tree…
        </div>
      `;
      return;
    }

    const html = `<ul class="space-y-1">${this.appKeys
      .map((key) => this.renderNode(key))
      .join('')}</ul>`;

    this.el.innerHTML = html;
  },

  renderNode(key) {
    const node = this.nodes.get(key);
    if (!node) return '';

    const collapsed = this.collapsed.has(key);
    const dead = node.info === 'dead';
    const hasChildren = !!node['has_children?'];
    const childrenKeys = Array.isArray(node.children_keys)
      ? node.children_keys
      : null;
    const stub = hasChildren && childrenKeys === null;

    const chevron = hasChildren
      ? `
        <button
          class="btn btn-ghost btn-xs h-5 min-h-0 w-5 p-0"
          data-toggle="expand"
          data-key="${escapeAttr(key)}"
          type="button"
        >
          ${chevronIcon(collapsed)}
        </button>
      `
      : '<span class="w-3.5"></span>';

    const badgeClass = badgeClassFor(node.type, node.info);
    const badgeLabel = BADGE_LABELS[node.type] || node.type || '?';
    const nameText = formatName(node.name);
    const infoLine = formatInfo(node.info);

    const childrenHtml =
      !collapsed && childrenKeys && childrenKeys.length > 0
        ? `<ul class="border-base-300 mt-0.5 ml-5 space-y-0.5 border-l pl-2">${childrenKeys
            .map((childKey) => this.renderNode(childKey))
            .join('')}</ul>`
        : '';

    // const stubHint =
    //   stub && collapsed
    //     ? `<div class="text-base-content/30 ml-12 text-xs italic">— click to expand</div>`
    //     : '';

    const stubHint = '';

    return `
      <li id="tree-node-${escapeAttr(domId(key))}" class="list-none">
        <div class="${[
          'flex items-center gap-2 rounded-md px-2 py-1.5 transition-colors',
          dead ? 'opacity-50' : 'hover:bg-base-200',
        ].join(' ')}">
          <div class="flex w-5 shrink-0 items-center justify-center">${chevron}</div>
          <span class="badge badge-xs shrink-0 ${badgeClass}">${badgeLabel}</span>
          <span class="${[
            'font-mono flex-1 truncate text-sm',
            dead ? 'text-base-content/40 line-through' : '',
          ].join(' ')}">${escapeHtml(nameText)}</span>
          <span class="text-base-content/40 shrink-0 text-xs">${escapeHtml(infoLine)}</span>
        </div>
        ${childrenHtml}
        ${stubHint}
      </li>
    `;
  },
};

function normalizeNode(node) {
  const copy = { ...node };
  if (copy.children_keys === 'not_loaded') copy.children_keys = null;
  return copy;
}

function normalizePatch(patch) {
  const copy = { ...patch };
  if (copy.children_keys === 'not_loaded') copy.children_keys = null;
  return copy;
}

function isRealPid(key) {
  return typeof key === 'string' && key.startsWith('<') && key.endsWith('>');
}

function chevronIcon(collapsed) {
  // Inline SVGs matching lucide chevron-right / chevron-down.
  if (collapsed) {
    return `<svg xmlns="http://www.w3.org/2000/svg" class="size-3.5" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="9 18 15 12 9 6"/></svg>`;
  }
  return `<svg xmlns="http://www.w3.org/2000/svg" class="size-3.5" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="6 9 12 15 18 9"/></svg>`;
}

function badgeClassFor(type, info) {
  if (info === 'dead') return 'badge-error';
  if (type === 'app') return 'badge-primary';
  if (type === 'supervisor') return 'badge-secondary';
  return 'badge-ghost';
}

function formatName(name) {
  if (name === null || name === undefined) return '';
  if (Array.isArray(name)) return name.map(formatName).join(':');
  if (typeof name === 'string') return name;
  return String(name);
}

function formatInfo(info) {
  if (!info) return '';
  if (info === 'dead') return 'dead';
  if (typeof info !== 'object') return '';
  const mem = formatBytes(info.memory);
  const mq = info.message_queue_len ?? 0;
  return `${mem} | mq: ${mq}`;
}

function formatBytes(n) {
  if (n === null || n === undefined) return '—';
  if (n === 0) return '0 B';
  if (n < 1024) return `${n} B`;
  if (n < 1_048_576) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / 1_048_576).toFixed(1)} MB`;
}

function domId(key) {
  return String(key).replace(/[.<>:,\s]/g, '-');
}

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function escapeAttr(s) {
  return escapeHtml(s);
}

export default SupervisionTree;
