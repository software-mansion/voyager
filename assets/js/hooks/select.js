// Closes a `<.select>` dropdown after a choice; blur drops DaisyUI's :focus-within.

const Select = {
  mounted() {
    this._onChange = () => {
      const focused = this.el.querySelector(':focus');
      if (focused instanceof HTMLElement) focused.blur();
    };

    this.el.addEventListener('change', this._onChange);
  },

  destroyed() {
    this.el.removeEventListener('change', this._onChange);
  },
};

export default Select;
