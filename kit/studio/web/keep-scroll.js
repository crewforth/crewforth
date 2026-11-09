// A panel drawn again from fresh data keeps the reader's place in it.
//
// The inspector, the List and the Timeline drawer are built anew on every frame the live stream sends, a few
// times a second while a session works. A box that scrolls is a new element after each frame, so it started at
// the top again, and anyone reading down a transcript or a long report was thrown back before they got there.
//
// A box is found again by where it sits under the panel: its class and how many boxes of that class come before
// it among its siblings, for each step down. That survives a redraw of the same view and does not need every
// builder to name its boxes. A box that is not there after the redraw is left alone, and one whose content is now
// shorter is clamped by the browser, as any scroll is.

function keyOf(el, parent) {
  const cls = typeof el.className === 'string' ? el.className : '';
  let n = 0;
  for (const sib of parent.children ?? []) {
    if (sib === el) break;
    if ((typeof sib.className === 'string' ? sib.className : '') === cls) n += 1;
  }
  return `${el.tagName ?? ''}.${cls}#${n}`;
}

/**
 * Every box under root (root included) that is scrolled away from its start, by its path.
 * @returns Map<path, { top, left }>
 */
export function scrollPlaces(root) {
  const places = new Map();
  if (!root) return places;
  const walk = (el, path) => {
    if ((el.scrollTop ?? 0) > 0 || (el.scrollLeft ?? 0) > 0) places.set(path, { top: el.scrollTop ?? 0, left: el.scrollLeft ?? 0 });
    for (const c of el.children ?? []) walk(c, `${path}/${keyOf(c, el)}`);
  };
  walk(root, '');
  return places;
}

/** Put each box found by scrollPlaces back where it was. Returns how many were found again. */
export function restoreScroll(root, places) {
  if (!root || !places?.size) return 0;
  let found = 0;
  const walk = (el, path) => {
    const p = places.get(path);
    if (p) {
      found += 1;
      if (p.top) el.scrollTop = p.top;
      if (p.left) el.scrollLeft = p.left;
    }
    for (const c of el.children ?? []) walk(c, `${path}/${keyOf(c, el)}`);
  };
  walk(root, '');
  return found;
}

/**
 * Draw root again with paint() and keep the reader's place in it. A different view (another node, another tab)
 * is a new page and starts at the top: pass its name as view, and a change of view drops the places kept.
 */
export function keepScroll(root, paint, view = null) {
  const same = !root || root.dataset?.scrollView === undefined || view === null || root.dataset.scrollView === String(view);
  const places = same ? scrollPlaces(root) : null;
  paint();
  if (root?.dataset && view !== null) root.dataset.scrollView = String(view);
  if (places) restoreScroll(root, places);
}
