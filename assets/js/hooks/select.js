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
      this.syncExpanded();
    };

    this._onChange = () => this.dismiss();

    this._onClick = (e) => {
      if (this.inContent(e.target)) this.dismiss();
    };

    el.addEventListener('change', this._onChange);
    el.addEventListener('click', this._onClick);
    el.addEventListener('toggle', this.syncExpanded);
    this.syncExpanded();
  },

  destroyed() {
    this.el.removeEventListener('change', this._onChange);
    this.el.removeEventListener('click', this._onClick);
    this.el.removeEventListener('toggle', this.syncExpanded);
  },
};

export default Select;
