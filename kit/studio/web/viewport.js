// A pane that pans and zooms one layer, and cards that can be dragged on it.
//
// The graph (canvas.js) and the project map (map.js) both draw cards on a layer the viewer moves around. This is
// that part, once: a drag on the empty pane pans, the wheel zooms about the pointer (or pans, when it is mostly
// sideways), Fit puts the whole picture in the pane, and a card dragged more than a few pixels is placed by hand.
// Where things go and what a card says stay with the view that owns them.
import { ZOOM, fitZoom } from './graph-plan.js';

const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));

export class Viewport {
  /**
   * @param pane   the element the pointer works on; its size is the pane's
   * @param layer  the element moved and scaled: one transform, so a zoom restyles nothing
   * @param skip   (target) => true when a press on it is not a pan (a card, a control on the pane)
   * @param onApply  called after every change of the view
   */
  constructor(pane, layer, { skip = () => false, onApply = () => {} } = {}) {
    this.pane = pane;
    this.layer = layer;
    this.skip = skip;
    this.onApply = onApply;
    this.view = { x: 0, y: 0, k: 1 };
    this.touched = false;        // the viewer moved the view themselves
    this.#wire();
  }

  #wire() {
    let panning = null;
    this.pane.addEventListener('pointerdown', (e) => {
      if (e.button !== 0) return;                 // right/middle must not pan
      if (this.skip(e.target)) return;
      panning = { px: e.clientX, py: e.clientY, x: this.view.x, y: this.view.y };
      this.pane.setPointerCapture(e.pointerId);
      this.pane.classList.add('cv-panning');
    });
    this.pane.addEventListener('pointermove', (e) => {
      if (!panning) return;
      this.view.x = panning.x + (e.clientX - panning.px);
      this.view.y = panning.y + (e.clientY - panning.py);
      this.touched = true;
      this.apply();
    });
    const endPan = () => { panning = null; this.pane.classList.remove('cv-panning'); };
    this.pane.addEventListener('pointerup', endPan);
    this.pane.addEventListener('pointercancel', endPan);

    this.pane.addEventListener('wheel', (e) => {
      e.preventDefault();
      const r = this.pane.getBoundingClientRect();
      const mx = e.clientX - r.left;
      const my = e.clientY - r.top;
      // deltaMode 1 is lines and 2 is pages; Firefox reports ~3 where Chrome reports ~100, which made zoom
      // imperceptible and pan crawl.
      const unit = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? r.height : 1;
      const dY = e.deltaY * unit;
      const dX = e.deltaX * unit;
      if (e.ctrlKey || e.metaKey || Math.abs(dY) > Math.abs(dX)) {
        this.zoomAbout(this.view.k * Math.exp(-dY * 0.0016), mx, my);
      } else {
        this.view.x -= dX;
        this.view.y -= dY;
      }
      this.touched = true;
      this.apply();
    }, { passive: false });
  }

  /** Zoom to `k`, keeping the world point under (mx, my) where it is. */
  zoomAbout(k, mx, my) {
    const next = clamp(k, ZOOM.min, ZOOM.max);
    this.view.x = mx - (mx - this.view.x) * (next / this.view.k);
    this.view.y = my - (my - this.view.y) * (next / this.view.k);
    this.view.k = next;
  }

  /** Step the zoom from a toolbar: about the middle of the pane. */
  zoomBy(factor) { this.zoomTo(this.view.k * factor); }

  zoomTo(k) {
    const r = this.pane.getBoundingClientRect();
    this.zoomAbout(k, r.width / 2, r.height / 2);
    this.touched = true;
    this.apply();
  }

  /** Turn `view` into pixels: the single place that does. */
  apply() {
    const { x, y, k } = this.view;
    this.layer.style.transform = `translate(${x}px, ${y}px) scale(${k})`;
    this.onApply();
  }

  /** The whole picture (width × height, in the layer's own pixels) in the pane, never above 100%. */
  /** Fit the picture to the pane; `floor` is a zoom it does not go under (the picture then starts at its top). */
  fit(width, height, floor = 0) {
    const r = this.pane.getBoundingClientRect();
    const k = Math.max(fitZoom(width, height, r.width, r.height), Math.min(floor, ZOOM.fitMax));
    this.view.k = k;
    this.view.x = Math.max(ZOOM.pad, (r.width - width * k) / 2);
    this.view.y = Math.max(ZOOM.pad, (r.height - height * k) / 2);
    this.touched = false;
    this.apply();
  }

  /** Bring a point of the layer to the middle of the pane, at least at `minK`. */
  centerOn(cx, cy, minK = 1) {
    const r = this.pane.getBoundingClientRect();
    this.view.k = clamp(Math.max(this.view.k, minK), ZOOM.min, ZOOM.max);
    this.view.x = r.width / 2 - cx * this.view.k;
    this.view.y = r.height / 2 - cy * this.view.k;
    this.touched = true;
    this.apply();
  }
}

/**
 * A card that can be placed by hand. A press that moves more than 3 px (at the pane's zoom) is a drag, and the
 * click that ends it is swallowed: without that, every reposition also toggled the selection.
 * @param scale  () => the pane's zoom
 * @param at     () => the card's position { x, y } when the drag starts
 * @param move   (x, y) => the card is now here
 * @param end    () => the drag is over (persist the place)
 * @param ignore (target) => true for a part of the card that answers the press itself
 */
export function draggable(el, { scale, at, move, end = () => {}, ignore = () => false }) {
  let drag = null;
  el.addEventListener('pointerdown', (e) => {
    if (e.button !== 0) return;
    e.stopPropagation();                       // do not pan the pane too
    if (ignore(e.target)) return;
    const p = at() ?? { x: 0, y: 0 };
    drag = { px: e.clientX, py: e.clientY, x: p.x, y: p.y, moved: false };
    el.setPointerCapture(e.pointerId);
  });
  el.addEventListener('pointermove', (e) => {
    if (!drag) return;
    const dx = (e.clientX - drag.px) / scale();
    const dy = (e.clientY - drag.py) / scale();
    if (!drag.moved && Math.abs(dx) <= 3 && Math.abs(dy) <= 3) return;
    drag.moved = true;
    el.classList.add('cv-dragging');
    move(Math.round(drag.x + dx), Math.round(drag.y + dy));
  });
  const stop = () => {
    if (!drag) return;
    if (drag.moved) { end(); el.dataset.suppressClick = '1'; }
    drag = null;
    el.classList.remove('cv-dragging');
  };
  el.addEventListener('pointerup', stop);
  el.addEventListener('pointercancel', stop);
}

/** Did a drag just end on this element? Answers once, so the click that ends a drag does nothing. */
export function swallowClick(el) {
  if (el.dataset.suppressClick !== '1') return false;
  el.dataset.suppressClick = '0';
  return true;
}
