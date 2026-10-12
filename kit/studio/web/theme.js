// The theme button. Dark is the panel's own theme; light is what the system asks for or the viewer picks.
//
// tokens.css decides what is drawn: an explicit data-theme on the root wins, and without one the system's
// preference does. So "which theme is showing" is not the attribute alone, and the button has to answer from the
// same two inputs the stylesheet uses — otherwise the first click on a light system sets "light" and nothing moves.
//
// The choice is remembered per browser. Storage that refuses (private mode, a blocked origin) costs the memory and
// not the click: the theme still switches for this page.
export const THEME_KEY = 'crewforth-studio-theme';

const chosen = (v) => (v === 'light' || v === 'dark' ? v : null);

/** What is on screen: the viewer's choice if there is one, the system's otherwise. */
export function effectiveTheme(choice, systemLight) {
  return chosen(choice) ?? (systemLight ? 'light' : 'dark');
}

/**
 * @param root        the element that carries data-theme (documentElement)
 * @param button      the control; its label always names the theme it switches TO
 * @param ls          a Storage, or anything with getItem/setItem; may throw on either
 * @param systemLight () => boolean, whether the system prefers light right now
 */
export function initTheme(root, button, ls, systemLight) {
  let saved = null;
  try { saved = chosen(ls.getItem(THEME_KEY)); } catch { /* blocked storage: start from the system's theme */ }
  if (saved) root.dataset.theme = saved;

  const label = () => {
    const to = effectiveTheme(root.dataset.theme, systemLight()) === 'light' ? 'dark' : 'light';
    button.setAttribute('aria-label', `Switch to ${to} theme`);
    button.title = `Switch to ${to} theme`;
  };
  label();

  button.addEventListener('click', () => {
    const next = effectiveTheme(root.dataset.theme, systemLight()) === 'light' ? 'dark' : 'light';
    root.dataset.theme = next;
    try { ls.setItem(THEME_KEY, next); } catch { /* blocked storage: switched, not remembered */ }
    label();
  });
  return label;
}
