// Positions a portaled tooltip element relative to its trigger.
//
// The tooltip content is teleported (via `<.portal>`) to a global target in
// the root layout, so it lives outside any modal/overflow/stacking context and
// can never be clipped. This hook lives on the trigger element and is
// responsible for showing, positioning, and hiding the teleported content.
//
// Two interaction modes:
//   * Hover/focus — a transient peek. The tip stays open while the cursor is
//     over the trigger or the tip (with a short grace period to cross the gap),
//     so it can host clickable content such as a "learn more" link.
//   * Click — pins the tip open until the user clicks it again, clicks outside,
//     or presses Escape. Pinning makes links trivial to reach.

const HOVER_DELAY_MS = 120;
// Grace period after the cursor leaves the trigger/tip before hiding, so the
// user can move across the gap into the tip without it vanishing.
const CLOSE_DELAY_MS = 120;
const GAP = 8;
const VIEWPORT_MARGIN = 8;

function positionTooltip(tipEl, trigger) {
  const position = trigger.dataset.tooltipPosition || 'top';

  // Reset before measuring. A stale `left` near the right edge shrinks the
  // shrink-to-fit available width, so the tip wraps into a tall column; the
  // inflated height then gets clamped to the top of the viewport.
  tipEl.style.top = '0px';
  tipEl.style.left = '0px';

  const tip = tipEl.getBoundingClientRect();
  const rect = trigger.getBoundingClientRect();

  let top;
  let left;

  switch (position) {
    case 'bottom':
      top = rect.bottom + GAP;
      left = rect.left + rect.width / 2 - tip.width / 2;
      break;
    case 'left':
      top = rect.top + rect.height / 2 - tip.height / 2;
      left = rect.left - tip.width - GAP;
      break;
    case 'right':
      top = rect.top + rect.height / 2 - tip.height / 2;
      left = rect.right + GAP;
      break;
    default:
      // top
      top = rect.top - tip.height - GAP;
      left = rect.left + rect.width / 2 - tip.width / 2;
  }

  // Clamp into the viewport so the tooltip is never cut off.
  left = Math.max(
    VIEWPORT_MARGIN,
    Math.min(left, window.innerWidth - tip.width - VIEWPORT_MARGIN)
  );
  top = Math.max(
    VIEWPORT_MARGIN,
    Math.min(top, window.innerHeight - tip.height - VIEWPORT_MARGIN)
  );

  tipEl.style.top = `${top}px`;
  tipEl.style.left = `${left}px`;
}

const Tooltip = {
  mounted() {
    this._openTimeout = null;
    this._closeTimeout = null;
    this._tipEl = null;
    this._pinned = false;
    this._hoverTrigger = false;
    this._hoverTip = false;
    // Track which global listeners are currently attached so they can be
    // added/removed lazily instead of one set per tooltip living for the whole
    // page lifetime. Scroll/resize are only needed while the tip is open;
    // pointerdown/keydown only while it is pinned.
    this._scrollResizeBound = false;
    this._pinListenersBound = false;
    // Interactive tooltips can be hovered into and pinned open with a click;
    // plain ones are a transient hover/focus peek that hides as soon as the
    // cursor leaves the trigger.
    this._interactive = this.el.dataset.tooltipInteractive === 'true';

    this.getTip = () => document.querySelector(this.el.dataset.tooltipTarget);
    this.hovering = () => this._hoverTrigger || this._hoverTip;

    // Bind hover listeners to the tip lazily, the first time it is shown — the
    // portaled element may not exist yet at mount time. Idempotent: the tip is
    // reused across re-renders, so we only ever bind once.
    this.bindTip = (tipEl) => {
      if (this._tipEl === tipEl) return;
      this._tipEl = tipEl;
      tipEl.addEventListener('mouseenter', this.onTipEnter);
      tipEl.addEventListener('mouseleave', this.onTipLeave);
    };

    // Global scroll/resize listeners only need to exist while this tip is
    // visible. Reposition (pinned) or hide (transient) on viewport changes.
    this.bindScrollResize = () => {
      if (this._scrollResizeBound) return;
      this._scrollResizeBound = true;
      window.addEventListener('scroll', this.onScrollResize, true);
      window.addEventListener('resize', this.onScrollResize);
    };

    this.unbindScrollResize = () => {
      if (!this._scrollResizeBound) return;
      this._scrollResizeBound = false;
      window.removeEventListener('scroll', this.onScrollResize, true);
      window.removeEventListener('resize', this.onScrollResize);
    };

    // Outside-click and Escape handling only need to exist while pinned.
    this.bindPinListeners = () => {
      if (this._pinListenersBound) return;
      this._pinListenersBound = true;
      document.addEventListener('pointerdown', this.onDocPointerDown);
      document.addEventListener('keydown', this.onKeydown);
    };

    this.unbindPinListeners = () => {
      if (!this._pinListenersBound) return;
      this._pinListenersBound = false;
      document.removeEventListener('pointerdown', this.onDocPointerDown);
      document.removeEventListener('keydown', this.onKeydown);
    };

    this.show = () => {
      clearTimeout(this._closeTimeout);
      const tipEl = this.getTip();
      if (!tipEl) return;
      if (this._interactive) this.bindTip(tipEl);
      // Position before revealing so getBoundingClientRect is accurate and the
      // tooltip doesn't flash at a stale spot for one frame.
      positionTooltip(tipEl, this.el);
      tipEl.classList.add('is-open');
      this.bindScrollResize();
    };

    this.hide = () => {
      clearTimeout(this._openTimeout);
      clearTimeout(this._closeTimeout);
      this._pinned = false;
      const tipEl = this.getTip();
      if (tipEl) {
        tipEl.classList.remove('is-open', 'is-pinned');
        tipEl.style.top = '';
        tipEl.style.left = '';
      }
      this.unbindScrollResize();
      this.unbindPinListeners();
    };

    this.reposition = () => {
      const tipEl = this.getTip();
      if (tipEl && tipEl.classList.contains('is-open')) {
        positionTooltip(tipEl, this.el);
      }
    };

    this.delayedShow = () => {
      clearTimeout(this._closeTimeout);
      clearTimeout(this._openTimeout);
      this._openTimeout = setTimeout(this.show, HOVER_DELAY_MS);
    };

    // Hide after a short grace period, unless the tip is pinned or the cursor
    // is still over the trigger/tip.
    this.scheduleClose = () => {
      clearTimeout(this._openTimeout);
      if (this._pinned) return;
      clearTimeout(this._closeTimeout);
      this._closeTimeout = setTimeout(() => {
        if (!this._pinned && !this.hovering()) this.hide();
      }, CLOSE_DELAY_MS);
    };

    this.onTriggerEnter = () => {
      this._hoverTrigger = true;
      this.delayedShow();
    };

    this.onTriggerLeave = () => {
      this._hoverTrigger = false;
      // Plain tooltips have no hover bridge — hide as soon as the trigger is
      // left. Interactive ones wait out the grace period.
      if (this._interactive) {
        this.scheduleClose();
      } else {
        this.hide();
      }
    };

    this.onTipEnter = () => {
      this._hoverTip = true;
      clearTimeout(this._closeTimeout);
    };

    this.onTipLeave = () => {
      this._hoverTip = false;
      this.scheduleClose();
    };

    // Click toggles the pinned state: pin → freeze open; unpin → fall back to
    // hover rules (stays if still hovered, otherwise closes).
    this.togglePin = (e) => {
      e.preventDefault();
      this._pinned = !this._pinned;
      if (this._pinned) {
        document.dispatchEvent(
          new CustomEvent('tooltip:pinned', { detail: { id: this.el.id } })
        );
        this.show();
        const tipEl = this.getTip();
        if (tipEl) tipEl.classList.add('is-pinned');
        this.bindPinListeners();
      } else {
        const tipEl = this.getTip();
        if (tipEl) tipEl.classList.remove('is-pinned');
        this.unbindPinListeners();
        if (!this.hovering()) this.hide();
      }
    };

    this.onDocPointerDown = (e) => {
      if (!this._pinned) return;
      const tipEl = this.getTip();
      if (this.el.contains(e.target) || (tipEl && tipEl.contains(e.target))) {
        return;
      }
      this.hide();
    };

    this.onKeydown = (e) => {
      if (e.key === 'Escape' && this._pinned) this.hide();
    };

    this.onScrollResize = () => {
      if (this._pinned) {
        this.reposition();
      } else {
        this.hide();
      }
    };

    this._onOtherPin = (e) => {
      if (this._pinned && e.detail.id !== this.el.id) this.hide();
    };
    document.addEventListener('tooltip:pinned', this._onOtherPin);

    this.el.addEventListener('mouseenter', this.onTriggerEnter);
    this.el.addEventListener('mouseleave', this.onTriggerLeave);
    this.el.addEventListener('focusin', this.show);
    this.el.addEventListener('focusout', this.onTriggerLeave);

    // Global scroll/resize and pin (pointerdown/keydown) listeners are attached
    // lazily in show()/togglePin() and torn down in hide(), so an idle tooltip
    // holds no global listeners.
    if (this._interactive) {
      this.el.addEventListener('click', this.togglePin);
    }
  },

  destroyed() {
    this.hide();
    document.removeEventListener('tooltip:pinned', this._onOtherPin);
    this.el.removeEventListener('mouseenter', this.onTriggerEnter);
    this.el.removeEventListener('mouseleave', this.onTriggerLeave);
    this.el.removeEventListener('focusin', this.show);
    this.el.removeEventListener('focusout', this.onTriggerLeave);
    if (this._tipEl) {
      this._tipEl.removeEventListener('mouseenter', this.onTipEnter);
      this._tipEl.removeEventListener('mouseleave', this.onTipLeave);
    }
    if (this._interactive) {
      this.el.removeEventListener('click', this.togglePin);
    }
    // hide() above already tore down the global scroll/resize and pin
    // listeners; these are belt-and-suspenders in case they were still bound.
    this.unbindScrollResize();
    this.unbindPinListeners();
  },
};

export default Tooltip;
