// The panel's language. English is the panel's own and the default; Turkish is a choice the viewer makes.
//
// The English sentence is the key. t() returns it unchanged unless Turkish is chosen and the dictionary holds it,
// so a sentence nobody has translated yet still reads, in English, rather than as a key or a blank. Whether every
// sentence HAS a translation is not left to that fallback: the Studio gate reads each t('…') in web/ and index.html
// and fails on a missing, extra or mismatched entry.
//
// The language is read once, when this module is first evaluated. Every module that renders text imports this one,
// so it is settled before any of them builds a label, including the word maps they build at load. Switching reloads
// the page for that reason: a label built in one language is not rebuilt in the other by anything less.
import { TR } from './i18n-tr.js';

export const LANG_KEY = 'crewforth-studio-lang';
const known = (v) => (v === 'en' || v === 'tr' ? v : null);

function saved() {
  // Through window, not globalThis: Node answers a bare localStorage with a warning, and the gate imports this.
  try { return known(globalThis.window?.localStorage?.getItem(LANG_KEY)); } catch { return null; /* blocked storage: English */ }
}

let lang = saved() ?? 'en';

export const currentLang = () => lang;
/** For the gate: the page itself switches by reloading, never by this. */
export function setLang(l) { lang = known(l) ?? 'en'; }

/** The sentence in the chosen language, with {name} filled from vars. */
export function t(en, vars) {
  const s = lang === 'tr' && Object.hasOwn(TR, en) ? TR[en] : en;
  return vars ? s.replace(/\{(\w+)\}/g, (m, k) => (Object.hasOwn(vars, k) ? String(vars[k]) : m)) : s;
}

/**
 * A sentence with elements in it ("Runs in <code>…</code> on branch <code>…</code>."): the translated sentence cut at
 * its {slots}, each slot replaced by the node given for it, so the words around them can move with the language.
 */
export function tParts(en, slots) {
  return t(en).split(/(\{\w+\})/).filter(Boolean)
    .map((p) => { const m = /^\{(\w+)\}$/.exec(p); return m && Object.hasOwn(slots, m[1]) ? slots[m[1]] : p; });
}

/** The locale numbers and clock times are written in. */
export const numLocale = () => (lang === 'tr' ? 'tr-TR' : 'en-US');

const ATTRS = ['aria-label', 'title', 'placeholder'];

/** index.html is written in English; this puts its words in the chosen language. A no-op in English. */
export function translateDom(root) {
  root.ownerDocument?.documentElement?.setAttribute('lang', lang);
  if (lang === 'en') return;
  for (const e of root.querySelectorAll('*')) {
    for (const a of ATTRS) {
      const v = e.getAttribute(a);
      if (v && Object.hasOwn(TR, v)) e.setAttribute(a, TR[v]);
    }
    for (const n of e.childNodes) {
      if (n.nodeType !== 3) continue;
      const s = n.nodeValue.trim();
      if (s && Object.hasOwn(TR, s)) n.nodeValue = n.nodeValue.replace(s, TR[s]);
    }
  }
}

/**
 * The language button. It names the language it switches TO, in that language, so a viewer who cannot read the
 * current one can still find the way back. The choice is remembered per browser; storage that refuses costs the
 * memory, and the page then reloads into the default.
 */
export function initLang(button, ls, reload) {
  const to = lang === 'tr' ? 'en' : 'tr';
  button.textContent = to.toUpperCase();
  const say = to === 'tr' ? 'Türkçe' : 'English';
  button.setAttribute('aria-label', say);
  button.title = say;
  button.addEventListener('click', () => {
    try { ls.setItem(LANG_KEY, to); } catch { /* blocked storage: nothing to remember it in */ }
    reload();
  });
}
