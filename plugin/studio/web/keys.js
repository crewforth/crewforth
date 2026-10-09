// Which key presses are shortcuts.
//
// The panel's shortcuts are single letters, and a single letter is also what someone types into a field, and what
// the browser's own shortcuts are made of once a modifier is held: Cmd+R reloads, Ctrl+F finds. A letter is a
// shortcut here only when it is neither.

/** Is the press going into something that takes text? */
export function typingIn(target) {
  if (!target) return false;
  const tag = String(target.tagName ?? '').toUpperCase();
  return tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || target.isContentEditable === true;
}

/**
 * The key of a press that is a shortcut, or null: null while Cmd, Ctrl or Alt is held (those belong to the browser
 * and the system), and null while the press is going into a field.
 */
export function shortcutOf(e) {
  if (!e || e.metaKey || e.ctrlKey || e.altKey) return null;
  if (typingIn(e.target)) return null;
  return typeof e.key === 'string' ? e.key : null;
}
