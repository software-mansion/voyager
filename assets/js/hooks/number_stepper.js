// Drives the −/+ buttons of a `<.input type="number">` stepper.
//
// The native number-input spinners are hidden (see number-input.css) because
// they render tiny and inconsistently across the WebKit/Chromium webviews Tauri
// embeds. This hook wires the two replacement buttons to the input: a click
// steps once, and holding a button repeats with a short acceleration delay.
//
// The buttons only mutate the input's value and dispatch a bubbling `input`
// event — the surrounding LiveView form picks the change up through its own
// phx-change / phx-debounce wiring, so the hook speaks no LiveView protocol.

const REPEAT_DELAY_MS = 400;
const REPEAT_INTERVAL_MS = 80;

const NumberStepper = {
  mounted() {
    this.input = this.el.querySelector('input[type="number"]');
    this.buttons = Array.from(this.el.querySelectorAll('[data-step]'));

    this.step = (direction) => {
      if (!this.input || this.input.disabled) return;

      const stepSize = Math.abs(parseFloat(this.input.step)) || 1;
      const min = this.input.min === '' ? null : parseFloat(this.input.min);
      const max = this.input.max === '' ? null : parseFloat(this.input.max);
      const current = parseFloat(this.input.value);
      const base = Number.isNaN(current) ? (min ?? 0) : current;

      let next = base + direction * stepSize;
      if (min !== null) next = Math.max(min, next);
      if (max !== null) next = Math.min(max, next);
      // Trim floating-point drift from fractional steps.
      next = Math.round(next * 1e6) / 1e6;

      if (next === current) return;
      this.input.value = String(next);
      this.input.dispatchEvent(new Event('input', { bubbles: true }));
    };

    this.stopRepeat = () => {
      clearTimeout(this._holdTimeout);
      clearInterval(this._holdInterval);
      this._holdTimeout = null;
      this._holdInterval = null;
    };

    this._onPointerDown = (e) => {
      // Primary button / touch / pen only.
      if (e.button !== undefined && e.button !== 0) return;
      // Keep focus on the input and avoid text selection while pressing.
      e.preventDefault();

      const direction = Number(e.currentTarget.dataset.step) < 0 ? -1 : 1;
      this.stopRepeat();
      this.step(direction);
      this._holdTimeout = setTimeout(() => {
        this._holdInterval = setInterval(
          () => this.step(direction),
          REPEAT_INTERVAL_MS
        );
      }, REPEAT_DELAY_MS);
    };

    this.buttons.forEach((btn) =>
      btn.addEventListener('pointerdown', this._onPointerDown)
    );
    // Releasing or cancelling the pointer anywhere ends a hold.
    window.addEventListener('pointerup', this.stopRepeat);
    window.addEventListener('pointercancel', this.stopRepeat);
  },

  destroyed() {
    this.stopRepeat();
    this.buttons.forEach((btn) =>
      btn.removeEventListener('pointerdown', this._onPointerDown)
    );
    window.removeEventListener('pointerup', this.stopRepeat);
    window.removeEventListener('pointercancel', this.stopRepeat);
  },
};

export default NumberStepper;
