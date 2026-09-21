// `<details open>` is the menu state; blur cannot close a CSS :focus-within dropdown.

const Select = {
  mounted() {
    const el = this.el;

    this.dismiss = () => {
      el.open = false;
    };

    this._onClick = (e) => {
      if (el.querySelector('.dropdown-content')?.contains(e.target))
        this.dismiss();
    };

    this._onOutside = (e) => {
      if (!el.open) return;
      if (e.type === 'pointerdown' && e.button !== 0) return;
      if (el.contains(e.target)) return;
      this.dismiss();
    };

    this._onKeyDown = (e) => {
      if (e.key === 'Escape' && el.open) {
        e.preventDefault();
        this.dismiss();
      }
    };

    this._onToggle = () => {
      if (el.open) return;
      const trigger = el.querySelector('summary');
      const active = document.activeElement;
      if (
        trigger instanceof HTMLElement &&
        el.contains(active) &&
        active !== trigger
      ) {
        trigger.focus({ preventScroll: true });
      }
    };

    el.addEventListener('click', this._onClick);
    el.addEventListener('keydown', this._onKeyDown);
    el.addEventListener('toggle', this._onToggle);
    document.addEventListener('pointerdown', this._onOutside);
    document.addEventListener('focusin', this._onOutside);
  },

  destroyed() {
    this.el.removeEventListener('click', this._onClick);
    this.el.removeEventListener('keydown', this._onKeyDown);
    this.el.removeEventListener('toggle', this._onToggle);
    document.removeEventListener('pointerdown', this._onOutside);
    document.removeEventListener('focusin', this._onOutside);
  },
};

export default Select;
