// `<details open>` is the menu state; blur cannot close a CSS :focus-within dropdown.

const Select = {
  mounted() {
    const el = this.el;
    this.trigger = el.querySelector('summary');

    this.inContent = (target) => {
      const content = el.querySelector('.dropdown-content');
      return (
        content instanceof HTMLElement &&
        target instanceof Node &&
        content.contains(target)
      );
    };

    this.syncExpanded = () => {
      if (!(this.trigger instanceof HTMLElement)) return;
      this.trigger.setAttribute('aria-expanded', el.open ? 'true' : 'false');
    };

    this.dismiss = () => {
      el.open = false;
    };

    this._onClick = (e) => {
      if (this.inContent(e.target)) this.dismiss();
    };

    this._onDocPointerDown = (e) => {
      if (!el.open || e.button !== 0) return;
      if (e.target instanceof Node && el.contains(e.target)) return;
      this.dismiss();
    };

    this._onDocFocusIn = (e) => {
      if (!el.open) return;
      if (e.target instanceof Node && el.contains(e.target)) return;
      this.dismiss();
    };

    this._onDocKeyDown = (e) => {
      if (e.key === 'Escape' && el.open) {
        e.preventDefault();
        this.dismiss();
      }
    };

    this._onToggle = () => {
      this.syncExpanded();
      if (el.open || !(this.trigger instanceof HTMLElement)) return;
      const active = document.activeElement;
      if (
        active instanceof Node &&
        el.contains(active) &&
        active !== this.trigger
      ) {
        this.trigger.focus({ preventScroll: true });
      }
    };

    el.addEventListener('click', this._onClick);
    el.addEventListener('toggle', this._onToggle);
    document.addEventListener('pointerdown', this._onDocPointerDown);
    document.addEventListener('focusin', this._onDocFocusIn);
    document.addEventListener('keydown', this._onDocKeyDown);
    this.syncExpanded();
  },

  destroyed() {
    this.el.removeEventListener('click', this._onClick);
    this.el.removeEventListener('toggle', this._onToggle);
    document.removeEventListener('pointerdown', this._onDocPointerDown);
    document.removeEventListener('focusin', this._onDocFocusIn);
    document.removeEventListener('keydown', this._onDocKeyDown);
  },
};

export default Select;
