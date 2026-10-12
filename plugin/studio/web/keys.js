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
 * The key of a press that is a shortcut, or null.
 *
 * Null while Cmd or Ctrl is held: those belong to the browser and the system. Null while the press is going into a
 * field. Alt is different, because on many keyboards it is how a symbol is typed at all: on a Turkish Mac "[" is
 * Option+8 and "]" is Option+9, and the key the browser reports is the symbol. So Alt refuses a letter (Alt+R is
 * not "r") and a named key, and lets a symbol through as the key it produced.
 */
export function shortcutOf(e) {
  if (!e || e.metaKey || e.ctrlKey) return null;
  if (typingIn(e.target)) return null;
  if (typeof e.key !== 'string') return null;
  if (e.altKey && (e.key.length !== 1 || LETTER.test(e.key))) return null;
  return e.key;
}
const LETTER = /^\p{L}$/u;
