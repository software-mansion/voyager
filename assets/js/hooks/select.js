// Blur closes DaisyUI :focus-within; preventDefault on a second trigger click so it cannot refocus.

const Select = {
  mounted() {
    this.trigger = this.el.querySelector('[role="button"]');

    this.syncExpanded = () => {
      if (!(this.trigger instanceof HTMLElement)) return;
      this.trigger.setAttribute(
        'aria-expanded',
        this.el.matches(':focus-within') ? 'true' : 'false'
      );
    };

    this.close = () => {
      const focused = this.el.querySelector(':focus');
      if (focused instanceof HTMLElement) focused.blur();
      this.syncExpanded();
    };

    this._onChange = () => this.close();

    this._onClick = (e) => {
      const content = this.el.querySelector('.dropdown-content');
      const target = e.target;
      if (
        content instanceof HTMLElement &&
        target instanceof Node &&
        content.contains(target)
      ) {
        this.close();
      }
    };

    this._onPointerDown = (e) => {
      if (e.button !== 0) return;

      const content = this.el.querySelector('.dropdown-content');
      const target = e.target;
      if (
        content instanceof HTMLElement &&
        target instanceof Node &&
        content.contains(target)
      ) {
        return;
      }

      if (this.el.matches(':focus-within')) {
        e.preventDefault();
        this.close();
      }
    };

    this._onFocusOut = () => {
      requestAnimationFrame(() => {
        if (this.el.isConnected) this.syncExpanded();
      });
    };

    this.el.addEventListener('change', this._onChange);
    this.el.addEventListener('click', this._onClick);
    this.el.addEventListener('pointerdown', this._onPointerDown);
    this.el.addEventListener('focusin', this.syncExpanded);
    this.el.addEventListener('focusout', this._onFocusOut);
  },

  destroyed() {
    this.el.removeEventListener('change', this._onChange);
    this.el.removeEventListener('click', this._onClick);
    this.el.removeEventListener('pointerdown', this._onPointerDown);
    this.el.removeEventListener('focusin', this.syncExpanded);
    this.el.removeEventListener('focusout', this._onFocusOut);
  },
};

export default Select;
