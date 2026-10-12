// A view that redraws itself does not redraw while a button is down on it.
//
// The Timeline and the List put their rows in again about once a second while something in them moves. A browser
// sends a click only when the element that took the press is still in the page at the release. A redraw between
// the two took that element out, and the press chose nothing: measured, 3 presses of 20 at an ordinary 90 ms, and
// 20 of 20 when the button was held longer than a redraw. Keeping the row's own element and refilling it does not
// help: what takes the press is the text inside it, and a press whose target is gone gets no click at all.
//
// So the redraw waits. While a press is down the view says "later", and when the press is over, and the click it
// made has been delivered, the view draws what it put off. A press that is held and held is not a click: after
// HOLD_MS the view stops waiting for it.

export const HOLD_MS = 3000;

export class Press {
  /**
   * @param redraw  called once after a press, if a redraw was put off during it
   * @param timers  { set(fn, ms) => id, clear(id) } — the page's setTimeout and clearTimeout, or a test's
   */
  constructor(redraw, timers = { set: (fn, ms) => setTimeout(fn, ms), clear: (id) => clearTimeout(id) }) {
    this.redraw = redraw;
    this.timers = timers;
    this.down = false;
    this.owed = false;
    this.cap = null;
  }

  /** A button went down on the view. */
  press() {
    this.down = true;
    this.timers.clear(this.cap);
    this.cap = this.timers.set(() => this.release(), HOLD_MS);
  }

  /** It came up, or was taken away. What was put off is drawn after the click has been delivered. */
  release() {
    if (!this.down) return;
    this.down = false;
    this.timers.clear(this.cap);
    this.cap = null;
    this.timers.set(() => { if (this.owed && !this.down) { this.owed = false; this.redraw(); } }, 0);
  }

  /**
   * Asked by the view at the top of its redraw: true means "not now". A redraw that does run settles the debt.
   */
  defer() {
    if (this.down) { this.owed = true; return true; }
    this.owed = false;
    return false;
  }

  /**
   * Watch a view. The press is seen on the view; the release is seen on the window, because a press that began
   * on a row can end anywhere. The space bar is a press too: a button answers it at the key's release.
   */
  watch(root, win) {
    root.addEventListener('pointerdown', () => this.press(), true);
    root.addEventListener('keydown', (e) => { if (e.key === ' ') this.press(); }, true);
    for (const type of ['pointerup', 'pointercancel', 'keyup']) win.addEventListener(type, () => this.release(), true);
    // The window losing the keyboard, not an element in it: a press moves the focus, and that blur is not a release.
    win.addEventListener('blur', (e) => { if (e.target === win) this.release(); });
    return this;
  }
}
