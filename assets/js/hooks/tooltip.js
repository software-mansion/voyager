// Positions a portaled tooltip element relative to its trigger.
//
// The tooltip content is teleported (via `<.portal>`) to a global target in
// the root layout, so it lives outside any modal/overflow/stacking context and
// can never be clipped. This hook lives on the trigger element and is
// responsible for showing, positioning, and hiding the teleported content.

const HOVER_DELAY_MS = 120;
const GAP = 8;
const VIEWPORT_MARGIN = 8;

function positionTooltip(tipEl, trigger) {
  const position = trigger.dataset.tooltipPosition || 'top';
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
    this._hoverTimeout = null;

    this.getTip = () => document.querySelector(this.el.dataset.tooltipTarget);

    this.show = () => {
      const tipEl = this.getTip();
      if (!tipEl) return;
      // Position while still invisible so getBoundingClientRect is accurate.
      tipEl.dataset.show = 'true';
      positionTooltip(tipEl, this.el);
    };

    this.hide = () => {
      clearTimeout(this._hoverTimeout);
      const tipEl = this.getTip();
      if (tipEl) tipEl.dataset.show = 'false';
    };

    this.delayedShow = () => {
      clearTimeout(this._hoverTimeout);
      this._hoverTimeout = setTimeout(this.show, HOVER_DELAY_MS);
    };

    this.el.addEventListener('mouseenter', this.delayedShow);
    this.el.addEventListener('mouseleave', this.hide);
    this.el.addEventListener('focusin', this.show);
    this.el.addEventListener('focusout', this.hide);
    window.addEventListener('scroll', this.hide, true);
    window.addEventListener('resize', this.hide);
  },

  destroyed() {
    this.hide();
    this.el.removeEventListener('mouseenter', this.delayedShow);
    this.el.removeEventListener('mouseleave', this.hide);
    this.el.removeEventListener('focusin', this.show);
    this.el.removeEventListener('focusout', this.hide);
    window.removeEventListener('scroll', this.hide, true);
    window.removeEventListener('resize', this.hide);
  },
};

export default Tooltip;
