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

    this._onKeyDown = (e) => {
      if (e.key === 'Escape' && el.open) {
        e.preventDefault();
        this.dismiss();
      }
    };

    this._onToggle = () => {
      this.syncExpanded();
      if (!el.open && this.trigger instanceof HTMLElement) {
        const active = document.activeElement;
        if (
          active instanceof Node &&
          el.contains(active) &&
          active !== this.trigger
        ) {
          this.trigger.focus({ preventScroll: true });
        }
      }
    };

    el.addEventListener('click', this._onClick);
    el.addEventListener('keydown', this._onKeyDown);
    el.addEventListener('toggle', this._onToggle);
    this.syncExpanded();
  },

  destroyed() {
    this.el.removeEventListener('click', this._onClick);
    this.el.removeEventListener('keydown', this._onKeyDown);
    this.el.removeEventListener('toggle', this._onToggle);
  },
};

export default Select;
