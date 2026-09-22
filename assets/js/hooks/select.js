// `<details open>` is the menu state; blur cannot close a CSS :focus-within dropdown.

const Select = {
  mounted() {
    const el = this.el;

    const dismiss = () => {
      el.open = false;
    };

    // Focus first: `toggle` is queued, after the radio has already blurred to body.
    const closeAndFocusTrigger = () => {
      el.querySelector('summary')?.focus({ preventScroll: true });
      dismiss();
    };

    this._onClick = (e) => {
      if (el.querySelector('.dropdown-content')?.contains(e.target))
        closeAndFocusTrigger();
    };

    this._onOutside = (e) => {
      if (!el.open) return;
      if (e.type === 'pointerdown' && e.button !== 0) return;
      if (el.contains(e.target)) return;
      dismiss();
    };

    this._onKeyDown = (e) => {
      if (e.key === 'Escape' && el.open) {
        e.preventDefault();
        closeAndFocusTrigger();
      }
    };

    el.addEventListener('click', this._onClick);
    el.addEventListener('keydown', this._onKeyDown);
    document.addEventListener('pointerdown', this._onOutside);
    document.addEventListener('focusin', this._onOutside);
  },

  destroyed() {
    this.el.removeEventListener('click', this._onClick);
    this.el.removeEventListener('keydown', this._onKeyDown);
    document.removeEventListener('pointerdown', this._onOutside);
    document.removeEventListener('focusin', this._onOutside);
  },
};

export default Select;
