// Blur closes DaisyUI :focus-within; preventDefault on a second trigger click so it cannot refocus.

const Select = {
  mounted() {
    this.close = () => {
      const focused = this.el.querySelector(':focus');
      if (focused instanceof HTMLElement) focused.blur();
    };

    this._onChange = () => this.close();

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

    this.el.addEventListener('change', this._onChange);
    this.el.addEventListener('pointerdown', this._onPointerDown);
  },

  destroyed() {
    this.el.removeEventListener('change', this._onChange);
    this.el.removeEventListener('pointerdown', this._onPointerDown);
  },
};

export default Select;
